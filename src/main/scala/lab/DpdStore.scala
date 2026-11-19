package lab

import java.nio.file.Path
import java.sql.{Connection, PreparedStatement, Types}
import scala.collection.mutable
import scala.util.Using
import zio.Task

final case class DpdImportSummary(sha256: String, products: Long, ingredients: Long,
    forms: Long, routes: Long, statuses: Long)

/** Replace the Canadian marketed-human snapshot in one MVCC transaction. */
object DpdStore:
  private val schema = "health_canada_dpd"

  private final case class Table(name: String, columns: String, dateColumns: Set[Int] = Set.empty):
    def insertSql: String =
      val placeholders = columns.split(",").map(_ => "?").mkString(",")
      s"INSERT INTO $schema.$name ($columns) VALUES ($placeholders)"

  // Column order follows each of the five headerless files in Health Canada's data dictionary.
  private val tables = Map(
    DpdFile.Product -> Table("product", "drug_code,product_categorization,class_name,din,brand_name,descriptor," +
      "pediatric_flag,accession_number,number_of_ais,last_update_date,ai_group_no,class_name_f,brand_name_f,descriptor_f", Set(9)),
    DpdFile.Ingredient -> Table("ingredient", "drug_code,ingredient_code,ingredient,ingredient_supplied_ind,strength,strength_unit," +
      "strength_type,dosage_value,base,dosage_unit,notes,ingredient_f,strength_unit_f,strength_type_f,dosage_unit_f"),
    DpdFile.Form -> Table("form", "drug_code,form_code,form,form_f"),
    DpdFile.Route -> Table("route", "drug_code,route_code,route,route_f"),
    DpdFile.Status -> Table("status", "drug_code,current_status_flag,status,history_date,status_f,lot_number,expiration_date", Set(3,6))
  )

  def importArchive(config: PGConfig, archive: Path, source: String): Task[DpdImportSummary] =
    PostgresStore.inTransaction(config) { c =>
      require(source.nonEmpty, "Missing DPD archive source")
      val digest = Rrf.hash(archive)
      // Acquire before first-use DDL or inspecting the existing manifest, even on identical retries.
      Using.resource(c.createStatement())(_.execute("SELECT pg_advisory_xact_lock(hashtextextended('health_canada_dpd/marketed', 0))"))
      PostgresStore.installSchema(c, "/db/dpd.sql")
      currentSnapshot(c) match
        case Some(current) if current.sha256 == digest => current
        case _ =>
          // DELETE is transactional and keeps the previous snapshot visible to concurrent readers.
          Using.resource(c.createStatement()) { statement =>
            Vector("snapshot", "status", "route", "form", "ingredient", "product").foreach { table =>
              statement.executeUpdate(s"DELETE FROM $schema.$table")
            }
          }
          val summary = insertRows(c, archive, digest)
          validateProducts(c)
          require(Rrf.hash(archive) == digest, "DPD archive changed during import")
          Using.resource(c.prepareStatement(s"INSERT INTO $schema.snapshot " +
              "(sha256,source,products,ingredients,forms,routes,statuses) VALUES (?,?,?,?,?,?,?)")) { p =>
            p.setString(1,digest)
            p.setString(2,source)
            Vector(summary.products,summary.ingredients,summary.forms,summary.routes,summary.statuses)
              .zipWithIndex.foreach((count,i) => p.setLong(i+3,count))
            p.executeUpdate()
          }
          summary
    }

  private def currentSnapshot(c: Connection): Option[DpdImportSummary] =
    Using.resource(c.createStatement()) { p =>
      Using.resource(p.executeQuery(s"SELECT sha256,products,ingredients,forms,routes,statuses FROM $schema.snapshot")) { r =>
        Option.when(r.next())(DpdImportSummary(r.getString(1),r.getLong(2),r.getLong(3),r.getLong(4),r.getLong(5),r.getLong(6)))
      }
    }

  private def insertRows(c: Connection, archive: Path, digest: String): DpdImportSummary =
    val products = mutable.Map.empty[Int, Boolean] // Includes excluded classes to distinguish orphans.
    val counts = mutable.Map.from(DpdFile.values.map(_ -> 0L))
    Using.Manager { use =>
      val statements = tables.map { (file, table) => file -> use(c.prepareStatement(table.insertSql)) }
      var active = Option.empty[DpdFile]
      DpdArchive.read(archive) { (file, row) =>
        if !active.contains(file) then
          active.foreach(previous => statements(previous).executeBatch())
          active = Some(file)
        val drugCode = row.head.toInt
        require(drugCode > 0, s"Invalid drug_code in $file")
        val human = if file == DpdFile.Product then
          require(row(2).nonEmpty && !products.contains(drugCode), s"Invalid class or duplicate DPD product $drugCode")
          val retain = row(2) == "Human"
          products(drugCode) = retain
          retain
        else products.getOrElse(drugCode, throw IllegalArgumentException(s"$file references unknown drug_code $drugCode"))
        if human then
          val statement = statements(file)
          bind(statement, drugCode, row, tables(file).dateColumns)
          statement.addBatch()
          counts(file) += 1
          if counts(file) % 500 == 0 then statement.executeBatch()
      }
      active.foreach(file => statements(file).executeBatch())
    }.get
    require(counts(DpdFile.Product) > 0, "No Human products in DPD archive")
    DpdImportSummary(digest,counts(DpdFile.Product),counts(DpdFile.Ingredient),
      counts(DpdFile.Form),counts(DpdFile.Route),counts(DpdFile.Status))

  private def bind(statement: PreparedStatement, drugCode: Int, row: Vector[String], dates: Set[Int]): Unit =
    statement.setInt(1, drugCode)
    for index <- 1 until row.size do
      if dates.contains(index) then
        if row(index).isEmpty then statement.setNull(index+1, Types.DATE)
        else statement.setObject(index+1, DpdArchive.date(row(index)))
      else statement.setString(index+1, row(index))

  private def validateProducts(c: Connection): Unit =
    val coverage = Vector("ingredient","form","route").map { table =>
      s"NOT EXISTS (SELECT FROM $schema.$table x WHERE x.drug_code = p.drug_code)"
    }.mkString(" OR ")
    val invalid = s"""SELECT p.drug_code FROM $schema.product p WHERE $coverage OR NOT EXISTS (
        SELECT FROM $schema.status s WHERE s.drug_code = p.drug_code AND current_status_flag = 'Y'
        HAVING count(*) = 1 AND bool_and(status = 'MARKETED')
      ) LIMIT 1"""
    Using.resource(c.createStatement()) { p =>
      Using.resource(p.executeQuery(invalid)) { r =>
        if r.next() then throw IllegalArgumentException(
          s"DPD product ${r.getInt(1)} requires an ingredient, form, route and exactly one current MARKETED status")
      }
    }
