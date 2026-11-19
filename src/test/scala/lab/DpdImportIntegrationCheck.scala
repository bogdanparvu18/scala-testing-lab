package lab

import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.{Files, Path}
import java.sql.{Connection, DriverManager}
import java.util.UUID
import java.util.zip.{ZipEntry, ZipOutputStream}
import scala.util.Using
import zio.*

/** Opt-in: Test/runMain lab.DpdImportIntegrationCheck. The PostgreSQL test role
  * needs CREATEDB so this check can create and remove its own isolated database.
  */
object DpdImportIntegrationCheck extends ZIOAppDefault:
  private def jdbc[A](config: PGConfig)(action: Connection => A): Task[A] = ZIO.attemptBlocking {
    val host = if config.host == "::1" then "[::1]" else config.host
    val url = s"jdbc:postgresql://$host:${config.port}/${config.database}"
    Using.resource(DriverManager.getConnection(url, config.user, config.password))(action)
  }

  private def execute(config: PGConfig, sql: String): Task[Unit] =
    jdbc(config)(c => Using.resource(c.createStatement())(_.execute(sql))).unit

  private def values(config: PGConfig, sql: String): Task[Vector[String]] = jdbc(config) { c =>
    Using.resource(c.createStatement()) { s =>
      Using.resource(s.executeQuery(sql)) { result =>
        val rows = Vector.newBuilder[String]
        while result.next() do rows += result.getString(1)
        rows.result()
      }
    }
  }

  private def row(values: String*): String =
    values.map(v => "\"" + v.replace("\"", "\"\"") + "\"").mkString(",") + "\r\n"

  private def fixture(code: String, din: String, label: String, orphan: Boolean = false, currentStatus: String = "MARKETED"): ZIO[Scope, Throwable, Path] =
    for
      path <- ZIO.acquireRelease(ZIO.attempt(Files.createTempFile("dpd-check-", ".zip")))(
        p => ZIO.attempt(Files.deleteIfExists(p)).orDie)
      _ <- ZIO.attemptBlocking {
        def product(id: String, kind: String, productDin: String, brand: String) =
          row(id, "", kind, productDin, brand, "", "N", "00001", "1", "01-NOV-2026", "", "", "", "")
        def ingredient(id: String) = row(id, "12", "DEMO INGREDIENT", "I", "1", "MG", "", "", "N", "", "", "", "", "", "")
        def status(id: String, current: String, name: String, date: String) = row(id, current, name, date, "", "", "")
        val history = status(code, "N", "APPROVED", "01-JAN-2025")
        val contents = Vector(
          "drug.txt" -> (product(code, "Human", din, label) + product("99", "Veterinary", "00000099", "Vet fixture")),
          "ingred.txt" -> (ingredient(code) + ingredient("99")),
          "form.txt" -> (row(code, "1", "TABLET", "") + row("99", "1", "TABLET", "")),
          "route.txt" -> (row(code, "2", "ORAL", "") + row(code, "3", "SYNTHETIC", "") + row("99", "2", "ORAL", "")),
          "status.txt" -> (history + history + status(code, "Y", currentStatus, "01-FEB-2025") +
            status("99", "Y", "MARKETED", "01-FEB-2025") +
            (if orphan then status("777", "Y", "MARKETED", "01-FEB-2025") else "")))
        Using.resource(new ZipOutputStream(Files.newOutputStream(path))) { zip =>
          contents.foreach { case (name, data) =>
            zip.putNextEntry(new ZipEntry(name))
            zip.write(data.getBytes(UTF_8))
            zip.closeEntry()
          }
        }
      }
    yield path

  private def verify(config: PGConfig, din: String, brand: String, sha: String): Task[Unit] =
    def check(sql: String, expected: String*) =
      values(config, sql).map(actual => require(actual == expected.toVector, s"$sql returned $actual; expected $expected"))
    for
      _ <- check("SELECT din || ':' || brand_name FROM health_canada_dpd.product", s"$din:$brand")
      _ <- check("SELECT ingredient FROM health_canada_dpd.ingredient", "DEMO INGREDIENT")
      _ <- check("SELECT form FROM health_canada_dpd.form", "TABLET")
      _ <- check("SELECT route FROM health_canada_dpd.route ORDER BY route", "ORAL", "SYNTHETIC")
      _ <- check("SELECT status FROM health_canada_dpd.status ORDER BY status", "APPROVED", "APPROVED", "MARKETED")
      _ <- check("SELECT sha256 FROM health_canada_dpd.snapshot", sha)
      _ <- check("SELECT message FROM rxnorm_lab.dpd_test_sentinel", "preserved")
    yield ()

  def run = ZIO.scoped {
    for
      admin <- PGConfig.fromEnvironment
      name = "dpd_test_" + UUID.randomUUID().toString.replace("-", "")
      db <- ZIO.acquireRelease(execute(admin, s"CREATE DATABASE $name").as(admin.copy(database = name)))(
        _ => execute(admin, s"DROP DATABASE $name").orDie)
      _ <- execute(db, "CREATE SCHEMA rxnorm_lab")
      _ <- execute(db, "CREATE TABLE rxnorm_lab.dpd_test_sentinel(message text)")
      _ <- execute(db, "INSERT INTO rxnorm_lab.dpd_test_sentinel VALUES ('preserved')")
      first <- fixture("1", "00000001", "Édition, A")
      second <- fixture("2", "00000002", "Fixture B")
      broken <- fixture("3", "00000003", "Broken fixture", orphan = true)
      stale <- fixture("4", "00000004", "Wrong current status", currentStatus = "DORMANT")
      a <- DpdStore.importArchive(db, first, "fixture A")
      _ <- verify(db, "00000001", "Édition, A", a.sha256)
      importedAt <- values(db, "SELECT imported_at FROM health_canada_dpd.snapshot")
      same <- DpdStore.importArchive(db, first, "fixture A")
      retryTime <- values(db, "SELECT imported_at FROM health_canada_dpd.snapshot")
      _ <- ZIO.attempt(require(retryTime == importedAt, "Identical snapshot was unnecessarily replaced"))
      _ <- ZIO.attempt(require(a == same, "Repeated import changed its row counts or digest"))
      b <- DpdStore.importArchive(db, second, "fixture B")
      _ <- ZIO.attempt(require(a.sha256 != b.sha256))
      _ <- verify(db, "00000002", "Fixture B", b.sha256)
      failure <- DpdStore.importArchive(db, broken, "orphan status fixture").either
      _ <- ZIO.attempt(require(failure.isLeft, "Expected orphan status to reject the entire snapshot"))
      _ <- verify(db, "00000002", "Fixture B", b.sha256)
      staleFailure <- DpdStore.importArchive(db, stale, "non-marketed fixture").either
      _ <- ZIO.attempt(require(staleFailure.isLeft, "Expected an inconsistent current status to reject the snapshot"))
      _ <- verify(db, "00000002", "Fixture B", b.sha256)
      // Two importers may finish in either order. All visible rows must come from one winner.
      _ <- DpdStore.importArchive(db, first, "fixture A").zipPar(DpdStore.importArchive(db, second, "fixture B"))
      current <- values(db, "SELECT sha256 FROM health_canada_dpd.snapshot")
      _ <- if current == Vector(a.sha256) then verify(db, "00000001", "Édition, A", a.sha256)
           else verify(db, "00000002", "Fixture B", b.sha256)
      _ <- Console.printLine("DPD PostgreSQL integration passed: class filter, DIN, linked rows, repeat/replace, rollback and concurrent import.")
    yield ()
  }
