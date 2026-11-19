package lab

import com.sun.net.httpserver.{HttpExchange, HttpServer}
import java.net.{InetSocketAddress, URLDecoder}
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.channels.{Channels, FileChannel}
import java.time.LocalDate
import java.util.concurrent.{ArrayBlockingQueue, Executors, RejectedExecutionException, ThreadPoolExecutor, TimeUnit}
import scala.util.{Try, Using}
import zio.*
import zio.json.*

final case class ProductSearchItem(rxcui: String, display: String, tty: String, release: String) derives JsonCodec
final case class ProductSearchResponse(
  schemaVersion: String, release: String, query: String, items: Vector[ProductSearchItem], hasMore: Boolean
) derives JsonCodec
final case class ProductSearchError(code: String, message: String) derives JsonCodec
final case class ProductSearchFailure(status: Int, code: String, detail: String) extends RuntimeException(detail)

@jsonNoExtraFields
private[lab] final case class RegimenCheckRequest(release: String, rxcui: String, din: String, sha256: String,
    dose: Option[Dose] = None, frequency: Option[String] = None) derives JsonCodec:
  def wellFormed: Boolean =
    ProductSearchQuery.validRelease(release) && rxcui.matches("[1-9][0-9]{0,19}") &&
      din.matches("[0-9]{8}") && sha256.matches("[a-f0-9]{64}") &&
      (dose.isDefined || frequency.isDefined) &&
      dose.forall(d => d.unit.length <= 12 && d.amount.precision <= 128 && math.abs(d.amount.scale.toLong) <= 128) &&
      frequency.forall(f => f.nonEmpty && f.length <= 120 && !f.exists(_.isControl))

final case class ProductSearchQuery(release: String, query: String, limit: Int):
  require(ProductSearchQuery.validRelease(release),"Invalid RxNorm release date")
  require(query == TextKey.normalize(query) && query.length >= 2 && query.length <= 100 &&
    !query.exists(_.isControl),"Search needs 2–100 normalized characters")
  require(limit >= 1 && limit <= 20,"Search limit must be between 1 and 20")

object ProductSearchQuery:
  def literalPrefix(query: String): String = query.replace("\\","\\\\").replace("%","\\%").replace("_","\\_") + "%"

  private[lab] def validRelease(release: String): Boolean =
    release.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}") && Try(LocalDate.parse(release)).toOption.exists(_.getYear > 0)

  private[lab] def parameters(rawQuery: String): Map[String,String] =
    require(rawQuery != null && rawQuery.length <= 2048,"Missing or oversized query")
    val entries = rawQuery.split("&",-1).toVector.map { part =>
      val split = part.split("=",2)
      require(split.length == 2,"Malformed query parameter")
      URLDecoder.decode(split(0),UTF_8) -> URLDecoder.decode(split(1),UTF_8)
    }
    require(entries.map(_._1).distinct.size == entries.size,"Duplicate query parameters")
    entries.toMap

  def parse(rawQuery: String): Either[ProductSearchFailure,ProductSearchQuery] =
    Try {
      val params=parameters(rawQuery)
      require(params.keySet.subsetOf(Set("release","q","limit")),"Unknown search parameter")
      val rawPrefix=params.getOrElse("q","")
      require(!rawPrefix.exists(_.isControl),"Search cannot contain control characters")
      ProductSearchQuery(params.getOrElse("release",""),TextKey.normalize(rawPrefix),
        params.getOrElse("limit","20").toInt)
    }.toEither.left.map(_ => ProductSearchFailure(400,"INVALID_SEARCH_QUERY",
      "Use release=YYYY-MM-DD, q with 2–100 characters, and limit between 1 and 20."))

/** Runs on loopback. Checking an order only needs its source identifiers and dosing fields. */
object ProductSearchService:
  private def respond(exchange: HttpExchange, status: Int, body: String): Unit =
    val bytes=body.getBytes(UTF_8)
    exchange.getResponseHeaders.set("Content-Type","application/json; charset=utf-8")
    try
      exchange.sendResponseHeaders(status,bytes.length)
      exchange.getResponseBody.write(bytes)
    finally exchange.close()

  private def error(exchange: HttpExchange, failure: ProductSearchFailure): Unit =
    respond(exchange,failure.status,ProductSearchError(failure.code,failure.detail).toJson)

  private def complete[A](exchange: HttpExchange, fallback: ProductSearchFailure)(operation: => Task[A])(send: A => Unit): Unit =
    val result = Unsafe.unsafe { implicit unsafe =>
      Runtime.default.unsafe.run(ZIO.suspendSucceed(operation).sandbox.either).getOrThrowFiberFailure()
    }
    result match
      case Right(value) => send(value)
      case Left(cause) => error(exchange,cause.failureOption.collect { case problem: ProductSearchFailure => problem }.getOrElse(fallback))

  private def sendPdf(exchange: HttpExchange, document: CachedMonograph, din: String): Unit =
    try
      Using.resource(FileChannel.open(document.path)) { channel =>
        exchange.getResponseHeaders.set("Content-Disposition",s"inline; filename=Health-Canada-$din.pdf")
        exchange.getResponseHeaders.set("Referrer-Policy","no-referrer")
        exchange.getResponseHeaders.set("Content-Type","application/pdf")
        exchange.sendResponseHeaders(200,channel.size())
        Channels.newInputStream(channel).transferTo(exchange.getResponseBody)
      }
    catch
      case _: java.nio.file.NoSuchFileException if exchange.getResponseCode == -1 =>
        error(exchange,ProductSearchFailure(404,"PDF_NOT_CACHED","The local PDF was removed. Select the product again."))
    finally exchange.close()

  private val searchUnavailable = ProductSearchFailure(503,"SEARCH_UNAVAILABLE","Local terminology search is temporarily unavailable.")
  private val canadianUnavailable = ProductSearchFailure(503,"CANADIAN_PRODUCTS_UNAVAILABLE","The Canadian product catalog is temporarily unavailable.")

  /** Port 0 is reserved for tests; Main requires an explicit nonzero port. */
  def start(port: Int, lookup: ProductSearchQuery => Task[ProductSearchResponse],
      monographs: Option[CanadianMonographAccess] = None): ZIO[Scope,Throwable,Int] =
    ZIO.acquireRelease(ZIO.attempt {
      require(port >= 0 && port <= 65535,"Invalid product-search port")
      val server=HttpServer.create(new InetSocketAddress("127.0.0.1",port),16)
      val executor=Executors.newSingleThreadExecutor()
      // DPD lookups, remote PDF downloads and PDF streams must not block keystroke completion.
      val documents=new ThreadPoolExecutor(3,3,0L,TimeUnit.SECONDS,new ArrayBlockingQueue[Runnable](12))
      server.setExecutor(executor)
      server.createContext("/", exchange => {
        val localPort=server.getAddress.getPort
        val host=Option(exchange.getRequestHeaders.getFirst("Host")).getOrElse("")
        val path=exchange.getRequestURI.getRawPath
        val raw=exchange.getRequestURI.getRawQuery
        exchange.getResponseHeaders.set("Cache-Control","no-store")
        exchange.getResponseHeaders.set("X-Content-Type-Options","nosniff")
        val localClient=Set(s"127.0.0.1:$localPort",s"localhost:$localPort").contains(host) &&
          !exchange.getRequestHeaders.containsKey("Origin")
        val previewRequest=monographs.nonEmpty && path == "/monograph.pdf" && exchange.getRequestMethod == "GET"
        if !localClient && !previewRequest then
          error(exchange,ProductSearchFailure(403,"LOCAL_CLIENT_REQUIRED","Only local editor clients are supported."))
        else if path != "/products" && !(monographs.nonEmpty && Set("/canadian-products","/monograph","/monograph.pdf","/validate-regimen").contains(path)) then
          error(exchange,ProductSearchFailure(404,"NOT_FOUND","Unknown endpoint."))
        else
          val method = if path == "/monograph" || path == "/validate-regimen" then "POST" else "GET"
          if exchange.getRequestMethod != method then
            exchange.getResponseHeaders.set("Allow",method)
            error(exchange,ProductSearchFailure(405,"METHOD_NOT_ALLOWED",s"Use $method for this endpoint."))
          else if path == "/products" then
            complete(exchange,searchUnavailable)(ZIO.fromEither(ProductSearchQuery.parse(raw)).flatMap(lookup)) {
              response => respond(exchange,200,response.toJson)
            }
          else if method == "POST" && exchange.getRequestHeaders.getFirst("X-Aurora-Client") != "vscode" then
            error(exchange,ProductSearchFailure(403,"LOCAL_CLIENT_REQUIRED","This endpoint requires an explicit local editor request."))
          else
            try documents.execute(() => handleCanadian(exchange,path,raw,monographs.get,localClient))
            catch case _: RejectedExecutionException =>
              error(exchange,ProductSearchFailure(503,"MONOGRAPH_BUSY","The document service is busy. Please retry."))
      })
      server.start()
      (server,executor,documents)
    }) { (server,executor,documents) => ZIO.attempt {
      server.stop(0)
      documents.shutdownNow()
      executor.shutdownNow()
      ()
    }.orDie }.map(_._1.getAddress.getPort)

  private def handleCanadian(exchange: HttpExchange, path: String, raw: String, service: CanadianMonographAccess, localClient: Boolean): Unit =
    if path == "/validate-regimen" then
      handleRegimenCheck(exchange, raw, service)
      return
    CanadianSelection.parse(raw,requireDin = path != "/canadian-products",previewRoute = path == "/monograph.pdf") match
      case Left(problem) => error(exchange,problem)
      case Right(query) if path == "/canadian-products" =>
        complete(exchange,canadianUnavailable)(service.candidates(query.release,query.rxcui)) {
          result => respond(exchange,200,result.toJson)
        }
      case Right(query) if path == "/monograph" =>
        complete(exchange,canadianUnavailable)(service.confirm(query.release,query.rxcui,query.din.get)) {
          result => respond(exchange,200,result.toJson)
        }
      case Right(query) =>
        val din=query.din.get
        val authorized=query.preview.fold(localClient)(proof => service.validPreview(query.release,query.rxcui,din,proof))
        if !authorized then
          error(exchange,ProductSearchFailure(403,"PREVIEW_LINK_REQUIRED","Open the document again from the editor."))
        else
          complete(exchange,canadianUnavailable)(service.document(query.release,query.rxcui,din,cacheOnly = true)) {
            case Some(document) if query.preview.exists(_.sha256 != document.sha256) =>
              error(exchange,ProductSearchFailure(409,"PDF_REVISION_CHANGED","A new monograph revision is available. Open it again from the editor."))
            case Some(document) => sendPdf(exchange,document,din)
            case None => error(exchange,ProductSearchFailure(404,"PDF_NOT_CACHED","No downloaded PDF is available for this DIN."))
          }

  private def handleRegimenCheck(exchange: HttpExchange, raw: String, service: CanadianMonographAccess): Unit =
    val badRequest = ProductSearchFailure(400, "INVALID_REGIMEN_REQUEST",
      "Supply the RxNorm release, RxCUI, confirmed DIN, PDF checksum, and a dose or frequency in a JSON body.")
    val mediaType = Option(exchange.getRequestHeaders.getFirst("Content-Type")).map(_.takeWhile(_ != ';').trim)
    if raw != null || !mediaType.exists(_.equalsIgnoreCase("application/json")) then error(exchange, badRequest)
    else
      complete(exchange, canadianUnavailable) {
        for
          bytes <- ZIO.attemptBlocking(exchange.getRequestBody.readNBytes(4097))
          _ <- ZIO.fail(ProductSearchFailure(413, "REQUEST_TOO_LARGE", "Regimen check requests are limited to 4 KiB."))
            .when(bytes.length > 4096)
          request <- ZIO.fromEither(String(bytes, UTF_8).fromJson[RegimenCheckRequest].toOption
            .filter(_.wellFormed).toRight(badRequest))
          result <- service.orderValidation.check(request.release, request.rxcui, request.din, request.sha256, request.dose, request.frequency)
        yield result
      } { result =>
        val status = result.status match
          case "withinMonograph"  => "valid"
          case "outsideMonograph" => "invalid"
          case _                  => "unverified"
        respond(exchange, 200, result.copy(status = status).toJson)
      }
