package lab

import java.net.URI
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.util.concurrent.atomic.AtomicInteger
import zio.*
import zio.json.*
import zio.test.*

object ProductSearchSpec extends ZIOSpecDefault:
  private val release="2099-01-01"
  private val item=ProductSearchItem("10","synthetic aspirin tablet","SCD",release)
  private def lookup(query: ProductSearchQuery): Task[ProductSearchResponse] =
    ZIO.succeed(ProductSearchResponse("1",query.release,query.query,Vector(item),false))
  private def request(port: Int,path: String,method: String = "GET",origin: Option[String] = None): Task[HttpResponse[String]] =
    ZIO.attemptBlocking {
      val builder=HttpRequest.newBuilder(URI.create(s"http://127.0.0.1:$port$path"))
        .timeout(java.time.Duration.ofSeconds(5)).method(method,HttpRequest.BodyPublishers.noBody())
      origin.foreach(builder.header("Origin",_))
      HttpClient.newHttpClient().send(builder.build(),HttpResponse.BodyHandlers.ofString())
    }
  def spec = suite("Product autocomplete search")(
    test("normalizes case and whitespace while retaining literal punctuation") {
      val parsed=ProductSearchQuery.parse(s"release=$release&q=%20%20ASPI%20%20RIN%20&limit=7")
      assertTrue(parsed == Right(ProductSearchQuery(release,"aspi rin",7)))
    },
    test("rejects absent, duplicate, unknown and malformed parameters") {
      val invalid=Vector(null,"",s"release=$release&q=as&q=asp",s"release=$release&q=as&patient=secret",
        s"release=$release&q=%ZZ",s"release=$release&q=as&limit=1.5",s"release=$release&q=as&limit=0")
      assertTrue(invalid.forall(ProductSearchQuery.parse(_).isLeft))
    },
    test("enforces prefix length, real release date and limit bounds") {
      val invalid=Vector(s"release=$release&q=a",s"release=$release&q=${"a"*101}",
        s"release=$release&q=ab&limit=21","release=2099-02-30&q=ab","release=0000-01-01&q=ab",s"release=$release&q=ab%00")
      assertTrue(invalid.forall(ProductSearchQuery.parse(_).isLeft),
        ProductSearchQuery.parse(s"release=$release&q=${"a"*100}&limit=20").isRight)
    },
    test("SQL prefix treats wildcard metacharacters as literals") {
      assertTrue(ProductSearchQuery.literalPrefix("as%_\\") == "as\\%\\_\\\\%")
    },
    test("long-lived HTTP service accepts repeated requests and returns IDs and release") {
      ZIO.scoped {
        for
          port <- ProductSearchService.start(0,lookup)
          first <- request(port,s"/products?release=$release&q=ASPI")
          second <- request(port,s"/products?release=$release&q=aspir")
        yield assertTrue(first.statusCode == 200,second.statusCode == 200,
          first.body.fromJson[ProductSearchResponse] == Right(ProductSearchResponse("1",release,"aspi",Vector(item),false)),
          first.headers.firstValue("Access-Control-Allow-Origin").isEmpty)
      }
    },
    test("bad input is rejected before invoking repository") {
      ZIO.scoped {
        val calls=new AtomicInteger()
        for
          port <- ProductSearchService.start(0,q => { calls.incrementAndGet(); lookup(q) })
          response <- request(port,s"/products?release=$release&q=a")
        yield assertTrue(response.statusCode == 400,calls.get == 0,
          response.body.fromJson[ProductSearchError].toOption.exists(_.code == "INVALID_SEARCH_QUERY"))
      }
    },
    test("unknown release and database failures return JSON without internal details") {
      ZIO.scoped {
        for
          unavailable <- ProductSearchService.start(0,_ => ZIO.fail(ProductSearchFailure(404,"RXNORM_RELEASE_UNAVAILABLE","Not ready")))
          broken <- ProductSearchService.start(0,_ => ZIO.fail(new IllegalStateException("private database details")))
          first <- request(unavailable,s"/products?release=$release&q=aspi")
          second <- request(broken,s"/products?release=$release&q=aspi")
        yield assertTrue(first.statusCode == 404,second.statusCode == 503,
          second.body.fromJson[ProductSearchError].toOption.exists(_.code == "SEARCH_UNAVAILABLE"),
          !second.body.contains("private database details"))
      }
    },
    test("rejects browser origins, non-GET methods and unknown routes") {
      ZIO.scoped {
        for
          port <- ProductSearchService.start(0,lookup)
          origin <- request(port,s"/products?release=$release&q=aspi",origin=Some("https://example.com"))
          method <- request(port,s"/products?release=$release&q=aspi",method="POST")
          path <- request(port,"/products/other")
        yield assertTrue(origin.statusCode == 403,method.statusCode == 405,path.statusCode == 404)
      }
    }
  )
