package lab

import com.sun.net.httpserver.HttpServer
import java.io.ByteArrayOutputStream
import java.net.{InetSocketAddress, URI}
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.{Files, Path}
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.{ZipEntry, ZipOutputStream}
import scala.jdk.CollectionConverters.*
import scala.util.Using
import zio.*
import zio.test.*

object DpdSourceSpec extends ZIOSpecDefault:
  private def archive(brand: String): Array[Byte] =
    val bytes = new ByteArrayOutputStream()
    Using.resource(new ZipOutputStream(bytes)) { zip =>
      for file <- DpdFile.values do
        val fields = Vector.fill(file.columnCount)("").updated(0, "42")
        val row = if file == DpdFile.Product then fields.updated(4, brand) else fields
        zip.putNextEntry(new ZipEntry(file.entryName))
        zip.write((row.mkString(",") + "\r\n").getBytes(UTF_8))
        zip.closeEntry()
    }
    bytes.toByteArray

  private def destination: ZIO[Scope, Throwable, Path] =
    ZIO.acquireRelease(ZIO.attemptBlocking(Files.createTempDirectory("dpd-repo-test-")))(root =>
      ZIO.attemptBlocking {
        Using.resource(Files.walk(root))(_.iterator().asScala.toVector.reverse.foreach(Files.deleteIfExists))
      }.orDie
    ).map(_.resolve("data").resolve("allfiles.zip"))

  private def server(status: Int, content: Array[Byte], requests: AtomicInteger = new AtomicInteger): ZIO[Scope, Throwable, URI] =
    ZIO.acquireRelease(ZIO.attemptBlocking {
      val http = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0)
      http.createContext("/allfiles.zip", exchange =>
        try
          requests.incrementAndGet()
          exchange.sendResponseHeaders(status, if content.isEmpty then -1L else content.length.toLong)
          if content.nonEmpty then Using.resource(exchange.getResponseBody)(_.write(content))
        finally exchange.close()
      )
      http.start()
      http
    })(http => ZIO.succeed(http.stop(0))).map(http => URI.create(s"http://127.0.0.1:${http.getAddress.getPort}/allfiles.zip"))

  private def fetch(url: URI, path: Path): Task[DpdSource] = ZIO.scoped(DpdSource.prepare(None, url, path))

  def spec = suite("DPD archive acquisition")(
    test("publishes the complete archive in the project and replaces it on a successful refresh") {
      ZIO.scoped {
        val first = archive("First")
        val next = archive("Next")
        for
          target <- destination
          url <- server(200, first)
          source <- fetch(url, target)
          original <- ZIO.attemptBlocking(Files.readAllBytes(target))
          refresh <- server(200, next)
          updated <- fetch(refresh, target)
          stored <- ZIO.attemptBlocking(Files.readAllBytes(target))
        yield assertTrue(source.archive == target, source.origin == url.toString, original.sameElements(first),
          updated.archive == target, updated.origin == refresh.toString, stored.sameElements(next))
      }
    },
    test("setup downloads the missing archive and reuses it without network access on subsequent runs") {
      ZIO.scoped {
        val bytes = archive("Setup")
        val requests = new AtomicInteger
        for
          target <- destination
          url <- server(200, bytes, requests)
          source <- ZIO.scoped(DpdSource.setup(url, target))
          unavailable <- server(503, Array.emptyByteArray, requests)
          reused <- ZIO.scoped(DpdSource.setup(unavailable, target).flatMap(source =>
            ZIO.attemptBlocking(Files.readAllBytes(source.archive))))
          stored <- ZIO.attemptBlocking(Files.readAllBytes(target))
          requestCount = requests.get()
        yield assertTrue(source.origin == url.toString, source.archive == target, stored.sameElements(bytes),
          reused.sameElements(bytes), requestCount == 1)
      }
    },
    test("setup reports how to refresh an invalid saved ZIP without contacting the server") {
      ZIO.scoped {
        val invalid = archive("Broken").dropRight(24)
        val requests = new AtomicInteger
        for
          target <- destination
          _ <- ZIO.attemptBlocking(Files.createDirectories(target.getParent))
          _ <- ZIO.attemptBlocking(Files.write(target, invalid))
          url <- server(200, archive("Available"), requests)
          result <- ZIO.scoped(DpdSource.setup(url, target)).either
          saved <- ZIO.attemptBlocking(Files.readAllBytes(target))
          message = result.left.toOption.map(_.getMessage).getOrElse("")
          requestCount = requests.get()
        yield assertTrue(requestCount == 0, saved.sameElements(invalid), message.contains(target.toString),
          message.contains("Invalid DPD ZIP"), message.contains("run import-dpd"))
      }
    },
    test("a failed first download reports the cause and leaves no archive in manual and setup modes") {
      ZIO.scoped {
        for
          target <- destination
          url <- server(503, Array.emptyByteArray)
          manual <- fetch(url, target).either
          setup <- ZIO.scoped(DpdSource.setup(url, target)).either
          absent <- ZIO.attemptBlocking(Files.notExists(target))
          messages = List(manual, setup).flatMap(_.left.toOption.map(_.getMessage))
          clear = messages.forall(message => message.contains("download failed") && message.contains("HTTP 503") &&
            message.contains(url.toString) && message.contains(target.toString) && message.contains("PostgreSQL import was not started"))
        yield assertTrue(absent, messages.size == 2, clear)
      }
    },
    test("failed refreshes do not reuse or replace the old file and a later retry can succeed") {
      ZIO.scoped {
        val first = archive("First")
        val next = archive("Next")
        for
          target <- destination
          url <- server(200, first)
          _ <- fetch(url, target)
          unavailable <- server(503, Array.emptyByteArray)
          empty <- server(200, Array.emptyByteArray)
          truncated <- server(200, next.dropRight(24))
          errors <- ZIO.foreach(List(unavailable, empty, truncated))(url => fetch(url, target).either)
          beforeRetry <- ZIO.attemptBlocking(Files.readAllBytes(target))
          parts <- ZIO.attemptBlocking {
            Using.resource(Files.list(target.getParent))(_.iterator().asScala.count(_.getFileName.toString.endsWith(".part")))
          }
          retry <- server(200, next)
          _ <- fetch(retry, target)
          afterRetry <- ZIO.attemptBlocking(Files.readAllBytes(target))
        yield assertTrue(errors.forall(_.isLeft), beforeRetry.sameElements(first), parts == 0,
          afterRetry.sameElements(next))
      }
    },
    test("concurrent imports each read the archive from their own successful download") {
      ZIO.scoped {
        val first = archive("First")
        val next = archive("Next")
        for
          target <- destination
          url <- server(200, first)
          refresh <- server(200, next)
          firstReady <- Promise.make[Nothing, Unit]
          secondStarted <- Promise.make[Nothing, Unit]
          firstBytes <- ZIO.scoped {
            for
              source <- DpdSource.prepare(None, url, target)
              _ <- firstReady.succeed(())
              _ <- secondStarted.await
              bytes <- ZIO.attemptBlocking(Files.readAllBytes(source.archive))
            yield bytes
          }.fork
          _ <- firstReady.await
          secondBytes <- ZIO.scoped {
            for
              _ <- secondStarted.succeed(())
              source <- DpdSource.prepare(None, refresh, target)
              bytes <- ZIO.attemptBlocking(Files.readAllBytes(source.archive))
            yield bytes
          }
          original <- firstBytes.join
        yield assertTrue(original.sameElements(first), secondBytes.sameElements(next))
      }
    },
    test("offline replay snapshots the input without contacting the server or replacing the project archive") {
      ZIO.scoped {
        val cached = archive("Cached")
        val offline = archive("Offline")
        for
          target <- destination
          _ <- ZIO.attemptBlocking(Files.createDirectories(target.getParent))
          _ <- ZIO.attemptBlocking(Files.write(target, cached))
          input = target.resolveSibling("manual.zip")
          _ <- ZIO.attemptBlocking(Files.write(input, offline))
          unavailable <- server(503, Array.emptyByteArray)
          result <- ZIO.scoped {
            DpdSource.prepare(Some(input), unavailable, target).flatMap(source =>
              ZIO.attemptBlocking((source, Files.readAllBytes(source.archive))))
          }
          removed <- ZIO.attemptBlocking(Files.notExists(result._1.archive))
          original <- ZIO.attemptBlocking(Files.readAllBytes(input))
          retained <- ZIO.attemptBlocking(Files.readAllBytes(target))
        yield assertTrue(result._1.origin == input.toUri.toString, result._2.sameElements(offline), removed,
          original.sameElements(offline), retained.sameElements(cached))
      }
    }
  )
