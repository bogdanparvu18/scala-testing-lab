package lab

import com.sun.net.httpserver.{HttpExchange, HttpServer}
import java.net.{InetSocketAddress, URLDecoder}
import java.nio.charset.StandardCharsets.UTF_8
import java.time.LocalDate
import java.util.concurrent.Executors
import scala.util.Try
import zio.*
import zio.json.*

final case class ProductSearchItem(rxcui: String, display: String, tty: String, release: String) derives JsonCodec
final case class ProductSearchResponse(
  schemaVersion: String, release: String, query: String, items: Vector[ProductSearchItem], hasMore: Boolean
) derives JsonCodec
final case class ProductSearchError(code: String, message: String) derives JsonCodec
final case class ProductSearchFailure(status: Int, code: String, detail: String) extends RuntimeException(detail)

final case class ProductSearchQuery(release: String, query: String, limit: Int):
  require(release.matches("\\d{4}-\\d{2}-\\d{2}") && Try(LocalDate.parse(release)).toOption.exists(_.getYear > 0),"Invalid RxNorm release date")
  require(query == TextKey.normalize(query) && query.length >= 2 && query.length <= 100 &&
    !query.exists(_.isControl),"Search needs 2–100 normalized characters")
  require(limit >= 1 && limit <= 20,"Search limit must be between 1 and 20")

object ProductSearchQuery:
  def literalPrefix(query: String): String = query.replace("\\","\\\\").replace("%","\\%").replace("_","\\_") + "%"

  def parse(rawQuery: String): Either[ProductSearchFailure,ProductSearchQuery] =
    Try {
      require(rawQuery != null && rawQuery.length <= 2048,"Missing or oversized search query")
      val entries = rawQuery.split("&",-1).toVector.map { part =>
        val split = part.split("=",2)
        require(split.length == 2,"Malformed search parameter")
        URLDecoder.decode(split(0),UTF_8) -> URLDecoder.decode(split(1),UTF_8)
      }
      require(entries.map(_._1).distinct.size == entries.size,"Duplicate search parameters")
      val params=entries.toMap
      require(params.keySet.subsetOf(Set("release","q","limit")),"Unknown search parameter")
      val rawPrefix=params.getOrElse("q","")
      require(!rawPrefix.exists(_.isControl),"Search cannot contain control characters")
      ProductSearchQuery(params.getOrElse("release",""),TextKey.normalize(rawPrefix),
        params.getOrElse("limit","20").toInt)
    }.toEither.left.map(_ => ProductSearchFailure(400,"INVALID_SEARCH_QUERY",
      "Use release=YYYY-MM-DD, q with 2–100 characters, and limit between 1 and 20."))

/** A JVM started once for the editor session. It searches local imported data,
  * accepts no source document/patient data and never creates a binding record.
  */
object ProductSearchService:
  private def respond(exchange: HttpExchange, status: Int, body: String): Unit =
    val bytes=body.getBytes(UTF_8)
    exchange.getResponseHeaders.set("Content-Type","application/json; charset=utf-8")
    exchange.getResponseHeaders.set("Cache-Control","no-store")
    exchange.getResponseHeaders.set("X-Content-Type-Options","nosniff")
    try
      exchange.sendResponseHeaders(status,bytes.length)
      exchange.getResponseBody.write(bytes)
    finally exchange.close()

  private def error(exchange: HttpExchange, failure: ProductSearchFailure): Unit =
    respond(exchange,failure.status,ProductSearchError(failure.code,failure.detail).toJson)

  /** Port 0 is reserved for tests; Main requires an explicit nonzero port. */
  def start(port: Int, lookup: ProductSearchQuery => Task[ProductSearchResponse]): ZIO[Scope,Throwable,Int] =
    ZIO.acquireRelease(ZIO.attempt {
      require(port >= 0 && port <= 65535,"Invalid product-search port")
      val server=HttpServer.create(new InetSocketAddress("127.0.0.1",port),16)
      val executor=Executors.newSingleThreadExecutor()
      server.setExecutor(executor)
      server.createContext("/", exchange => {
        val localPort=server.getAddress.getPort
        val host=Option(exchange.getRequestHeaders.getFirst("Host")).getOrElse("")
        if !Set(s"127.0.0.1:$localPort",s"localhost:$localPort").contains(host) ||
            exchange.getRequestHeaders.containsKey("Origin") then
          error(exchange,ProductSearchFailure(403,"LOCAL_CLIENT_REQUIRED","Only local editor clients are supported."))
        else if exchange.getRequestURI.getPath != "/products" then
          error(exchange,ProductSearchFailure(404,"NOT_FOUND","Unknown search endpoint."))
        else if exchange.getRequestMethod != "GET" then
          exchange.getResponseHeaders.set("Allow","GET")
          error(exchange,ProductSearchFailure(405,"METHOD_NOT_ALLOWED","Use GET for product search."))
        else ProductSearchQuery.parse(exchange.getRequestURI.getRawQuery) match
          case Left(failure) => error(exchange,failure)
          case Right(query) =>
            val result=Unsafe.unsafe { implicit unsafe =>
              Runtime.default.unsafe.run(ZIO.suspendSucceed(lookup(query)).sandbox.either).getOrThrowFiberFailure()
            }
            result match
              case Right(response) => respond(exchange,200,response.toJson)
              case Left(cause) => cause.failureOption match
                case Some(failure: ProductSearchFailure) => error(exchange,failure)
                case _ => error(exchange,ProductSearchFailure(503,"SEARCH_UNAVAILABLE","Local terminology search is temporarily unavailable."))
      })
      server.start()
      (server,executor)
    }) { (server,executor) => ZIO.attempt {
      server.stop(0)
      executor.shutdownNow()
      ()
    }.orDie }.map(_._1.getAddress.getPort)
