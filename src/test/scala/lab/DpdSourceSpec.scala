package lab

import com.sun.net.httpserver.HttpServer
import java.net.{InetSocketAddress, URI}
import java.nio.file.Files
import scala.util.Using
import zio.*
import zio.test.*

object DpdSourceSpec extends ZIOSpecDefault:
  private val content = Array[Byte](80, 75, 3, 4)

  private def server(status: Int): ZIO[Scope, Throwable, URI] =
    ZIO.acquireRelease(ZIO.attemptBlocking {
      val http = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0)
      http.createContext("/allfiles.zip", exchange =>
        try
          exchange.sendResponseHeaders(status, content.length.toLong)
          Using.resource(exchange.getResponseBody)(_.write(content))
        finally exchange.close()
      )
      http.start()
      http
    })(http => ZIO.succeed(http.stop(0))).map(http => URI.create(s"http://127.0.0.1:${http.getAddress.getPort}/allfiles.zip"))

  def spec = suite("DPD archive acquisition")(
    test("download copies the response, records the URL and removes its temporary file") {
      ZIO.scoped {
        for
          url <- server(200)
          result <- ZIO.scoped {
            DpdSource.prepare(None, url).flatMap(source =>
              ZIO.attemptBlocking((source, Files.readAllBytes(source.archive))))
          }
          removed <- ZIO.attemptBlocking(Files.notExists(result._1.archive))
        yield assertTrue(result._1.origin == url.toString, result._2.sameElements(content), removed)
      }
    },
    test("HTTP errors stop the import") {
      ZIO.scoped {
        for
          url <- server(503)
          result <- DpdSource.prepare(None, url).either
        yield assertTrue(result.left.exists(_.getMessage.contains("HTTP 503")))
      }
    },
    test("offline replay snapshots the original file without modifying it") {
      ZIO.scoped {
        for
          input <- ZIO.acquireRelease(ZIO.attemptBlocking(Files.createTempFile("dpd-local-test-", ".zip")))(
            file => ZIO.attemptBlocking(Files.deleteIfExists(file)).orDie)
          _ <- ZIO.attemptBlocking(Files.write(input, content))
          source <- ZIO.scoped(DpdSource.prepare(Some(input)))
          removed <- ZIO.attemptBlocking(Files.notExists(source.archive))
          original <- ZIO.attemptBlocking(Files.readAllBytes(input))
        yield assertTrue(source.origin == input.toUri.toString, removed, original.sameElements(content))
      }
    }
  )
