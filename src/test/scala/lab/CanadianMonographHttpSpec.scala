package lab

import java.net.{Socket, URI}
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.Files
import java.util.concurrent.atomic.{AtomicInteger, AtomicReference}
import org.apache.pdfbox.pdmodel.{PDDocument, PDPage, PDPageContentStream}
import org.apache.pdfbox.pdmodel.font.{PDType1Font, Standard14Fonts}
import scala.util.Using
import zio.*
import zio.json.*
import zio.test.*

object CanadianMonographHttpSpec extends ZIOSpecDefault:
  private val release = "2099-11-02"
  private val rxcui = "12345"
  private val din = "00000042"
  private val query = s"release=$release&rxcui=$rxcui"
  private val confirmed = s"$query&din=$din"
  private val product = CanadianProduct(din,17,"Synthetic Tablet",Vector("Ingredient"),Vector("Tablet"),Vector("Oral"))
  private val items = CanadianProductCandidates(release,rxcui,"synthetic branded tablet",Vector(product))
  private val client = HttpClient.newHttpClient()
  private def candidates(version: String, code: String): Task[CanadianProductCandidates] =
    if version == release && code == rxcui then ZIO.succeed(items)
    else ZIO.fail(ProductSearchFailure(404,"RXNORM_PRODUCT_NOT_FOUND","Unknown product."))

  private def request(port: Int, path: String, post: Boolean = false, editor: Boolean = true, browser: Boolean = false): Task[HttpResponse[Array[Byte]]] =
    ZIO.attemptBlocking {
      val builder=HttpRequest.newBuilder(URI.create(s"http://127.0.0.1:$port$path")).timeout(java.time.Duration.ofSeconds(5))
      if editor then builder.header("X-Aurora-Client","vscode")
      if browser then builder.header("Origin","https://example.test")
      if post then builder.POST(HttpRequest.BodyPublishers.noBody())
      client.send(builder.build(),HttpResponse.BodyHandlers.ofByteArray())
    }
  /** The JDK HTTP client protects Host, so send the header a port forwarder would use. */
  private def forwardedStatus(port: Int, path: String): Task[String] = ZIO.attemptBlocking {
    Using.resource(new Socket("127.0.0.1",port)) { socket =>
      socket.setSoTimeout(5000)
      socket.getOutputStream.write(s"GET $path HTTP/1.1\r\nHost: forwarded.editor.example\r\nConnection: close\r\n\r\n".getBytes(UTF_8))
      String(socket.getInputStream.readAllBytes(),UTF_8).takeWhile(_ != '\r')
    }
  }
  private def body(response: HttpResponse[Array[Byte]]): String = String(response.body,UTF_8)
  private def start(service: CanadianMonographAccess) =
    ProductSearchService.start(0,q => ZIO.succeed(ProductSearchResponse("1",q.release,q.query,Vector.empty,false)),Some(service))

  def spec = suite("Canadian monograph endpoints")(
    test("confirmation extracts from the selected DIN's presentation and keeps the signed PDF when no passage matches") {
      ZIO.scoped {
        val otherDin = "00000043"
        val selected = CanadianProduct(din, 17, "Test Tablet", Vector("TEST INGREDIENT 40 MG"), Vector("TABLET"), Vector("ORAL"))
        val other = selected.copy(din = otherDin, drugCode = 18, ingredients = Vector("TEST INGREDIENT 60 MG"))
        val presentations = items.copy(items = Vector(selected, other))
        for
          file <- ZIO.acquireRelease(ZIO.attemptBlocking(Files.createTempFile("monograph-regimens-", ".pdf")))(p =>
            ZIO.attemptBlocking(Files.deleteIfExists(p)).orDie)
          _ <- ZIO.attemptBlocking(Using.resource(new PDDocument()) { pdf =>
            val page = new PDPage()
            pdf.addPage(page)
            Using.resource(new PDPageContentStream(pdf, page)) { stream =>
              stream.beginText()
              stream.setFont(new PDType1Font(Standard14Fonts.FontName.HELVETICA), 11)
              stream.setLeading(14)
              stream.newLineAtOffset(40, 700)
              Vector("Dosage and Administration:", "Immediate Release:", "Adults and children 12 years of age and older",
                "40 mg tablet: 40 mg to 80 mg every 4 to 6 hours, as required,",
                "not to exceed 240 mg per day.").foreach { line =>
                stream.showText(line)
                stream.newLine()
              }
              stream.endText()
            }
            pdf.save(file.toFile)
          })
          document = CachedMonograph(file, "https://pdf.hres.ca/dpd_pm/00012345.PDF", "c"*64, Some("2025-11-01"))
          service = new CanadianMonographAccess((_,_) => ZIO.succeed(presentations),
            (_,_) => ZIO.some(document), (_,_) => ZIO.some(document))
          port <- start(service)
          response <- request(port, s"/monograph?$confirmed", post = true)
          result <- ZIO.fromEither(body(response).fromJson[MonographResult]).orDieWith(new RuntimeException(_))
          different <- request(port, s"/monograph?$query&din=$otherDin", post = true)
          unmatched <- ZIO.fromEither(body(different).fromJson[MonographResult]).orDieWith(new RuntimeException(_))
        yield assertTrue(response.statusCode == 200, result.dosagePage.contains(1),
          result.regimenSuggestions.exists(s => s.page == 1 && s.dose.contains("40") && s.frequency.nonEmpty &&
            s.context.contains("Adults") && s.evidence.contains("240 mg per day")),
          unmatched.dosagePage.contains(1), unmatched.regimenSuggestions.isEmpty,
          unmatched.pdfPath.exists(_.contains(otherDin)), unmatched.sha256.contains(document.sha256))
      }
    },
    test("candidate list, explicit confirmation, offline PDF preview and release validation") {
      ZIO.scoped {
        val fetches = new AtomicInteger()
        val views = new AtomicInteger()
        for
          file <- ZIO.acquireRelease(ZIO.attemptBlocking(Files.createTempFile("monograph-http-", ".pdf")))(p =>
            ZIO.attemptBlocking(Files.deleteIfExists(p)).orDie)
          _ <- ZIO.attemptBlocking(Using.resource(new PDDocument()){ pdf =>
            pdf.addPage(new PDPage()); pdf.save(file.toFile)
          })
          bytes <- ZIO.attemptBlocking(Files.readAllBytes(file))
          document = CachedMonograph(file,"https://pdf.hres.ca/dpd_pm/00012345.PDF","0"*64,Some("2025-11-01"))
          service = new CanadianMonographAccess(candidates,(code,d) => ZIO.attempt {
            require(code == 17 && d == din); fetches.incrementAndGet(); Some(document)
          },(_,_) => ZIO.succeed { views.incrementAndGet(); Some(document) })
          port <- start(service)
          listed <- request(port,s"/canadian-products?$query")
          invalidRelease <- request(port,s"/canadian-products?release=2098-01-01&rxcui=$rxcui")
          downloaded <- request(port,s"/monograph?$confirmed",post=true)
          result <- ZIO.fromEither(body(downloaded).fromJson[MonographResult]).orDieWith(new RuntimeException(_))
          shown <- request(port,result.pdfPath.getOrElse("/missing"))
        yield assertTrue(body(listed).fromJson[CanadianProductCandidates] == Right(items),
          invalidRelease.statusCode == 404, result.status == "available", result.sha256.contains(document.sha256),
          result.revision == document.revision, result.sourceUrl.contains(document.url), result.regimenSuggestions.isEmpty,
          !body(downloaded).contains(file.toString),
          shown.statusCode == 200, shown.headers.firstValue("Content-Type").orElse("") == "application/pdf",
          shown.body.sameElements(bytes), fetches.get == 1, views.get == 1)
      }
    },
    test("ineligible DIN, browser posts, wrong method and malformed identifiers never download") {
      ZIO.scoped {
        val fetches = new AtomicInteger()
        val calls = new AtomicInteger()
        val service=new CanadianMonographAccess((v,id) => ZIO.succeed(calls.incrementAndGet()) *> candidates(v,id),
          (_,_) => ZIO.succeed { fetches.incrementAndGet(); None },(_,_) => ZIO.dieMessage("unexpected read"))
        for
          port <- start(service)
          wrongDin <- request(port,s"/monograph?$query&din=00009999",post=true)
          invalid <- request(port,s"/monograph?$confirmed&url=https://example.test",post=true)
          old <- request(port,s"/monograph?release=$release&rxcui=12346&din=$din",post=true)
          browser <- request(port,s"/monograph?$confirmed",post=true,browser=true)
          simple <- request(port,s"/monograph?$confirmed",post=true,editor=false)
          get <- request(port,s"/monograph?$confirmed")
          path <- request(port,s"/monograph.pdf/other?$confirmed")
          traversal <- request(port,s"/monograph.pdf?$query&din=..%2F..%2Fetc")
        yield assertTrue(wrongDin.statusCode == 409,invalid.statusCode == 400,old.statusCode == 404,
          browser.statusCode == 403,simple.statusCode == 403,get.statusCode == 405,path.statusCode == 404,
          traversal.statusCode == 400,calls.get == 2,fetches.get == 0)
      }
    },
    test("forwarded hosts can preview only the signed document and revision") {
      ZIO.scoped {
        for
          file <- ZIO.acquireRelease(ZIO.attemptBlocking(Files.createTempFile("monograph-proxy-", ".pdf")))(p =>
            ZIO.attemptBlocking(Files.deleteIfExists(p)).orDie)
          _ <- ZIO.attemptBlocking(Using.resource(new PDDocument()){ pdf =>
            pdf.addPage(new PDPage()); pdf.save(file.toFile)
          })
          document = CachedMonograph(file,"https://pdf.hres.ca/dpd_pm/00012345.PDF","a"*64,None)
          current = new AtomicReference(document)
          service = new CanadianMonographAccess(candidates,(_,_) => ZIO.some(document),(_,_) => ZIO.some(current.get))
          port <- start(service)
          result <- request(port,s"/monograph?$confirmed",post=true)
          metadata <- ZIO.fromEither(body(result).fromJson[MonographResult]).orDieWith(new RuntimeException(_))
          path = metadata.pdfPath.getOrElse("/missing")
          forwarded <- forwardedStatus(port,path)
          unsigned <- forwardedStatus(port,s"/monograph.pdf?$confirmed")
          other <- forwardedStatus(port,path.replace("din="+din,"din=00000043"))
          changed <- forwardedStatus(port,path.replace("sha256="+document.sha256,"sha256="+("b"*64)))
          api <- forwardedStatus(port,s"/canadian-products?$query")
          _ <- ZIO.succeed(current.set(document.copy(sha256="b"*64)))
          superseded <- forwardedStatus(port,path)
        yield assertTrue(forwarded.contains("200"),unsigned.contains("403"),other.contains("403"),
          changed.contains("403"),api.contains("403"),superseded.contains("409"))
      }
    },
    test("a missing document, failed transfer and missing local copy have distinct responses") {
      ZIO.scoped {
        val absent=new CanadianMonographAccess(candidates,(_,_) => ZIO.none,(_,_) => ZIO.none)
        val failed=new CanadianMonographAccess(candidates,(_,_) => ZIO.fail(java.io.IOException("private details")),(_,_) => ZIO.none)
        for
          one <- start(absent)
          two <- start(failed)
          missing <- request(one,s"/monograph?$confirmed",post=true)
          missingFile <- request(one,s"/monograph.pdf?$confirmed")
          error <- request(two,s"/monograph?$confirmed",post=true)
        yield assertTrue(missing.statusCode == 200,body(missing).fromJson[MonographResult] == Right(MonographResult("unavailable")),
          missingFile.statusCode == 404,error.statusCode == 502,!body(error).contains("private details"))
      }
    },
    test("autocomplete can finish while a remote monograph request is pending") {
      ZIO.scoped {
        for
          started <- Promise.make[Nothing,Unit]
          finish <- Promise.make[Nothing,Unit]
          service = new CanadianMonographAccess(candidates,(_,_) => started.succeed(()) *> finish.await.as(None),(_,_) => ZIO.none)
          port <- start(service)
          pending <- request(port,s"/monograph?$confirmed",post=true).fork
          _ <- started.await
          search <- request(port,s"/products?release=$release&q=tyl").ensuring(finish.succeed(()))
          response <- pending.join
        yield assertTrue(search.statusCode == 200,response.statusCode == 200)
      }
    }
  )
