package lab

import java.io.{ByteArrayOutputStream, IOException, OutputStream}
import java.net.{InetSocketAddress, URI}
import com.sun.net.httpserver.HttpServer
import java.security.MessageDigest
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.{Files, Path}
import org.apache.pdfbox.pdmodel.{PDDocument, PDPage}
import scala.jdk.CollectionConverters.*
import scala.util.Using
import zio.*
import zio.test.*

object MonographCacheSpec extends ZIOSpecDefault:
  private val tablet = "00559407"
  private val caplet = "00723908"
  private val firstUrl = "https://pdf.hres.ca/dpd_pm/00076531.PDF"
  private val nextUrl = "https://pdf.hres.ca/dpd_pm/00076532.PDF"

  private def row(label: String, value: String): String =
    s"""<div class="row"><p><strong>$label:</strong></p><p>$value</p></div>"""

  private def page(din: String, link: String): String =
    row("<abbr>DIN</abbr>", din) + row("Product Monograph/Veterinary Labelling",
      s"""<strong>Date:</strong> <span>2024-07-03</span><span><a href="$link">PDF</a></span>""")

  private def pdf(title: String): Array[Byte] =
    val bytes = new ByteArrayOutputStream()
    Using.resource(new PDDocument()) { d =>
      d.addPage(new PDPage())
      d.getDocumentInformation.setTitle(title)
      d.save(bytes)
    }
    bytes.toByteArray

  private def tempDirectory = ZIO.acquireRelease(ZIO.attemptBlocking(Files.createTempDirectory("dpd-monographs-")))(path =>
    ZIO.attemptBlocking {
      Using.resource(Files.walk(path))(_.iterator().asScala.toVector.reverse.foreach(Files.deleteIfExists))
    }.orDie)

  private class Server:
    var data = pdf("first edition")
    var address = firstUrl
    var pageFor: String => String = din => page(din, address)
    var offline = false
    var pageCount = 0
    var downloadCount = 0
    def transfer(uri: URI, limit: Long, out: OutputStream): Unit =
      if offline then throw IOException("offline")
      if uri.getHost == "pdf.hres.ca" then
        downloadCount += 1
        out.write(data)
      else
        pageCount += 1
        val din = if uri.getQuery.endsWith("=5255") then tablet else caplet
        out.write(pageFor(din).getBytes(UTF_8))

  def spec = suite("Health Canada monograph cache")(
    test("DINs sharing a document download it once, including concurrent requests; a new cache instance works offline") {
      ZIO.scoped {
        val server = new Server
        for
          root <- tempDirectory
          cache = new MonographCache(root, server.transfer)
          pair <- cache.resolve(5255, tablet).zipPar(cache.resolve(8387, caplet))
          _ <- ZIO.succeed(server.offline = true)
          next = new MonographCache(root, server.transfer)
          local <- next.resolve(5255, tablet)
          missing <- next.cached(99, tablet)
          entries <- next.indexedProducts
          saved = local.exists(d => d.revision.contains("2024-07-03") && d.url == firstUrl && Files.isRegularFile(d.path))
        yield assertTrue(pair._1 == pair._2, local == pair._1, saved, server.pageCount == 2, server.downloadCount == 1,
          missing.isEmpty, entries == Vector(5255 -> tablet, 8387 -> caplet))
      }
    },
    test("a refresh keeps prior PDFs and an unsuccessful refresh preserves the current verified binding") {
      ZIO.scoped {
        val server = new Server
        for
          root <- tempDirectory
          cache = new MonographCache(root, server.transfer)
          first <- cache.resolve(5255, tablet).someOrFailException
          _ <- ZIO.succeed { server.address = nextUrl; server.data = "invalid PDF".getBytes(UTF_8) }
          failed <- cache.resolve(5255, tablet, refresh = true).either
          afterFailure <- cache.cached(5255, tablet)
          _ <- ZIO.succeed(server.data = pdf("new edition"))
          second <- cache.resolve(5255, tablet, refresh = true).someOrFailException
          active <- cache.cached(5255, tablet)
          saved = Files.isRegularFile(first.path) && Files.isRegularFile(second.path)
        yield assertTrue(failed.isLeft, afterFailure.contains(first), first.sha256 != second.sha256,
          saved, active.contains(second))
      }
    },
    test("cold restoration validates the pinned bytes before publishing, and cannot supersede newer or withdrawn bindings") {
      ZIO.scoped {
        val server = new Server
        val sha = java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(server.data))
        val pinned = MonographDocument(firstUrl, Some("2024-07-03"), sha)
        for
          root <- tempDirectory
          cache = new MonographCache(root, server.transfer)
          mismatch <- cache.restoreShared(5255, tablet, pinned.copy(sha256 = "a" * 64)).either
          entries <- cache.indexedProducts
          wrongBytesPublished = Files.exists(root.resolve("documents").resolve(sha + ".pdf"))
          saved <- cache.restoreShared(5255, tablet, pinned).someOrFailException
          _ <- ZIO.succeed { server.address = nextUrl; server.data = pdf("new edition") }
          updated <- cache.resolve(5255, tablet, refresh = true).someOrFailException
          retained <- cache.restoreShared(5255, tablet, pinned)
          _ <- ZIO.succeed(server.pageFor = din => row("DIN", din + " Electronic product monograph is not available"))
          _ <- cache.resolve(5255, tablet, refresh = true)
          withdrawn <- cache.restoreShared(5255, tablet, pinned)
          originalsPreserved = Files.isRegularFile(saved.path) && Files.isRegularFile(updated.path)
        yield assertTrue(mismatch.isLeft, entries.isEmpty, !wrongBytesPublished, saved.sha256 == sha,
          retained.contains(updated), withdrawn.isEmpty, originalsPreserved)
      }
    },
    test("only transient HTTP failures can activate the pinned-source fallback") {
      ZIO.scoped {
        for
          http <- ZIO.acquireRelease(ZIO.attemptBlocking {
            val server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0)
            server.createContext("/", exchange =>
              try exchange.sendResponseHeaders(exchange.getRequestURI.getPath.drop(1).toInt, -1)
              finally exchange.close())
            server.start()
            server
          })(server => ZIO.succeed(server.stop(0)))
          results <- ZIO.foreach(List(301, 404, 429, 503)) { status =>
            val uri = URI.create(s"http://127.0.0.1:${http.getAddress.getPort}/$status")
            ZIO.attemptBlocking(MonographCache.download(uri, 4096, new ByteArrayOutputStream())).either.map {
              case Left(f: MonographNetworkFailure) => f.uri == uri
              case _ => false
            }
          }
        yield assertTrue(results == List(false, false, true, true))
      }
    },
    test("a damaged cached PDF is excluded from reads and is repaired on selection") {
      ZIO.scoped {
        val server = new Server
        for
          root <- tempDirectory
          cache = new MonographCache(root, server.transfer)
          downloaded <- cache.resolve(5255, tablet).someOrFailException
          _ <- ZIO.attemptBlocking(Files.writeString(downloaded.path, "partial transfer"))
          damaged <- cache.cached(5255, tablet)
          recovered <- cache.resolve(5255, tablet)
          restored = Rrf.hash(downloaded.path) == downloaded.sha256
        yield assertTrue(damaged.isEmpty, restored, recovered.contains(downloaded), server.downloadCount == 2)
      }
    },
    test("an explicitly unavailable monograph differs from unexpected markup or a mismatched DIN") {
      ZIO.scoped {
        val server = new Server
        server.pageFor = din => row("<abbr>DIN</abbr>", s"<span>$din</span> Electronic product monograph is not available")
        for
          root <- tempDirectory
          cache = new MonographCache(root, server.transfer)
          unavailable <- cache.resolve(5255, tablet)
          known <- cache.knownUnavailable(5255, tablet)
          _ <- ZIO.succeed(server.pageFor = _ => row("DIN", tablet))
          offline <- cache.resolve(5255, tablet)
          unknown <- cache.resolve(5255, tablet, refresh = true).either
          _ <- ZIO.succeed(server.pageFor = _ => page(caplet, firstUrl))
          mismatch <- cache.resolve(5255, tablet, refresh = true).either
          _ <- ZIO.succeed(server.pageFor = _ => page(tablet, "https://other.invalid/dpd_pm/00076531.PDF"))
          wrongHost <- cache.resolve(5255, tablet, refresh = true).either
          malformed <- cache.resolve(5255, "../bad").either
        yield assertTrue(unavailable.isEmpty, known, offline.isEmpty, unknown.isLeft, mismatch.isLeft, wrongHost.isLeft,
          malformed.isLeft, server.downloadCount == 0, server.pageCount == 4)
      }
    }
  )
