package lab

import java.io.{ByteArrayOutputStream, IOException, OutputStream}
import java.net.{HttpURLConnection, URI}
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.{Files, Path, StandardCopyOption, StandardOpenOption}
import org.apache.pdfbox.Loader
import org.jsoup.Jsoup
import scala.jdk.CollectionConverters.*
import scala.util.Using
import zio.*
import zio.json.*

final class MonographNetworkFailure(val uri: URI, detail: String, cause: Throwable = null)
  extends IOException(detail, cause)

final case class CachedMonograph(path: Path, url: String, sha256: String, revision: Option[String])

private[lab] case class MonographDocument(url: String, revision: Option[String], sha256: String) derives JsonCodec
private[lab] case class MonographIndexEntry(drugCode: Int, din: String, document: Option[MonographDocument]) derives JsonCodec

/** One positive index entry per Canadian presentation. Immutable PDFs are shared by content.
  * Document addresses come from English DPD product pages or a bundled, hash-pinned snapshot of those pages.
  */
final class MonographCache private[lab] (directory: Path, transfer: (URI, Long, OutputStream) => Unit):
  import MonographCache.*

  def this(root: Path = Path.of("data", "monographs")) = this(root, MonographCache.download)

  private val root = directory.toAbsolutePath.normalize()
  private val products = root.resolve("products")
  private val documents = root.resolve("documents")
  private val sources = root.resolve("sources")

  // The HTTP service exposes only files under this cache. Never follow links placed
  // in an index, document directory or file, or let a link redirect cache writes.
  private def local(path: Path): Path =
    require(path.startsWith(root), "Monograph path is outside the cache")
    var check = path
    while check != null && (check.startsWith(root) || check == root.getParent) do
      if Files.isSymbolicLink(check) then throw IOException(s"Symbolic link in monograph cache: $check")
      check = check.getParent
    path

  private def entryPath(drugCode: Int, din: String): Path =
    require(drugCode > 0 && din.matches("[0-9]{8}"), "Expected a positive DPD drug code and an eight-digit DIN")
    local(products.resolve(s"$drugCode-$din.json"))

  private def readJson[A: JsonDecoder](path: Path): Option[A] =
    Option.unless(Files.notExists(local(path))) {
      if Files.size(path) > 16384 then throw IOException(s"Oversized monograph index entry: $path")
      Files.readString(path, UTF_8).fromJson[A].fold(
        detail => throw IOException(s"Invalid monograph index entry at $path: $detail"), identity)
    }

  private def entry(drugCode: Int, din: String): Option[MonographIndexEntry] =
    readJson[MonographIndexEntry](entryPath(drugCode, din)).map { e =>
      require(e.drugCode == drugCode && e.din == din, s"Monograph index mismatch for DIN $din")
      e
    }

  private def verified(document: MonographDocument): Option[CachedMonograph] =
    pdfAddress(document.url)
    require(document.sha256.matches("[0-9a-f]{64}"), "Invalid cached monograph SHA-256")
    val path = local(documents.resolve(document.sha256 + ".pdf"))
    Option.when(Files.isRegularFile(path) && hasPdfEnvelope(path) && Rrf.hash(path) == document.sha256)(
      CachedMonograph(path, document.url, document.sha256, document.revision))

  def cached(drugCode: Int, din: String): Task[Option[CachedMonograph]] = ZIO.attemptBlocking {
    entry(drugCode, din).flatMap(_.document).flatMap(verified)
  }

  def knownUnavailable(drugCode: Int, din: String): Task[Boolean] = ZIO.attemptBlocking {
    entry(drugCode, din).exists(_.document.isEmpty)
  }

  /** Includes prior selections whose official page explicitly reported no electronic monograph. */
  def indexedProducts: Task[Vector[(Int, String)]] = ZIO.attemptBlocking {
    if Files.notExists(local(products)) then Vector.empty
    else Using.resource(Files.list(products)) { entries =>
      entries.iterator().asScala.collect { case file if file.getFileName.toString.matches("[0-9]+-[0-9]{8}\\.json") =>
        val key = file.getFileName.toString.stripSuffix(".json").split("-")
        (key(0).toInt, key(1))
      }.toVector.sorted
    }
  }

  def resolve(drugCode: Int, din: String, refresh: Boolean = false): Task[Option[CachedMonograph]] = ZIO.attemptBlocking {
    val index = entryPath(drugCode, din)
    withWriteLock {
      val previous = entry(drugCode, din)
      val local = if refresh then None else previous.flatMap(_.document).flatMap(verified)
      if !refresh && previous.exists(_.document.isEmpty) then None
      else local.orElse {
        val page = URI.create(s"https://health-products.canada.ca/dpd-bdpp/info?lang=eng&code=$drugCode")
        val html = new ByteArrayOutputStream()
        transfer(page, pageLimit, html)
        val document = lookup(html.toString(UTF_8), din).map { (address, revision) =>
          resolveDocument(address, revision)
        }
        writeJson(index, MonographIndexEntry(drugCode, din, document).toJson)
        document.map(asCached)
      }
    }
  }

  /** Restore a bundled historical revision on a cold machine during a DPD page outage.
    * Concurrent successful page checks (including a withdrawal) take precedence.
    */
  private[lab] def restoreShared(drugCode: Int, din: String, pinned: MonographDocument): Task[Option[CachedMonograph]] =
    ZIO.attemptBlocking {
      val index = entryPath(drugCode, din)
      withWriteLock {
        entry(drugCode, din) match
          case Some(record) if !record.document.contains(pinned) =>
            record.document.map { active =>
              verified(active).getOrElse(throw IOException(s"The newer cached binding for DIN $din needs repair"))
            }
          case _ =>
            val saved = verified(pinned).getOrElse {
              asCached(downloadDocument(pdfAddress(pinned.url), pinned.revision, Some(pinned.sha256)))
            }
            writeJson(index, MonographIndexEntry(drugCode, din, Some(pinned)).toJson)
            Some(saved)
      }
    }

  private def asCached(document: MonographDocument): CachedMonograph =
    CachedMonograph(documents.resolve(document.sha256 + ".pdf"), document.url, document.sha256, document.revision)

  // Atomic index replacements allow concurrent offline readers. Writers may be in different
  // processes (installer and editor), or in different threads sharing a JVM.
  private def withWriteLock[A](operation: => A): A = writeLock.synchronized {
    Files.createDirectories(local(root))
    Using.resource(FileChannel.open(local(root.resolve(".lock")), StandardOpenOption.CREATE, StandardOpenOption.WRITE)) { channel =>
      Using.resource(channel.lock())(_ => operation)
    }
  }

  private def resolveDocument(address: URI, revision: Option[String]): MonographDocument =
    val id = address.getPath.split("/").last.takeWhile(_.isDigit)
    val sourcePath = sources.resolve(id + ".json")
    val previous = readJson[MonographDocument](sourcePath)
    previous.filter(d => d.url == address.toString && d.revision == revision && verified(d).isDefined).getOrElse {
      val document = downloadDocument(address, revision, None)
      writeJson(sourcePath, document.toJson)
      document
    }

  private def downloadDocument(address: URI, revision: Option[String], expectedSha: Option[String]): MonographDocument =
    Files.createDirectories(local(documents))
    val part = Files.createTempFile(documents, ".download-", ".part")
    try
      Using.resource(Files.newOutputStream(part))(out => transfer(address, pdfLimit, out))
      val sha = Rrf.hash(part)
      if expectedSha.exists(_ != sha) then throw IOException(s"Monograph SHA-256 differs from the pinned revision: $address")
      if !hasPdfEnvelope(part) then throw IOException(s"Incomplete or invalid monograph PDF from $address")
      Using.resource(Loader.loadPDF(part.toFile)) { parsed =>
        if parsed.getNumberOfPages < 1 then throw IOException("The monograph PDF contains no pages")
      }
      val destination = local(documents.resolve(sha + ".pdf"))
      if !Files.exists(destination) || Rrf.hash(destination) != sha then publish(part, destination)
      MonographDocument(address.toString, revision, sha)
    finally Files.deleteIfExists(part)

  private def writeJson(path: Path, text: String): Unit =
    Files.createDirectories(local(path).getParent)
    val part = Files.createTempFile(path.getParent, ".index-", ".part")
    try
      Files.writeString(part, text + "\n", UTF_8)
      publish(part, path)
    finally Files.deleteIfExists(part)

  private def publish(temp: Path, destination: Path): Unit =
    Files.move(temp, destination, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    ()

object MonographCache:
  private val writeLock = new Object()
  private val pageLimit = 2L * 1024 * 1024
  private val pdfLimit = 64L * 1024 * 1024

  private def hasPdfEnvelope(path: Path): Boolean =
    Using.resource(FileChannel.open(path, StandardOpenOption.READ)) { file =>
      val size = file.size()
      if size < 10 || size > pdfLimit then false
      else
        val start = ByteBuffer.allocate(5)
        val end = ByteBuffer.allocate(size.min(1024).toInt)
        file.read(start)
        file.read(end, size - end.capacity())
        new String(start.array(), UTF_8) == "%PDF-" && new String(end.array(), java.nio.charset.StandardCharsets.ISO_8859_1).contains("%%EOF")
    }

  private def pdfAddress(href: String): URI =
    val uri = URI.create(href)
    require(uri.getScheme == "https" && "pdf.hres.ca".equalsIgnoreCase(uri.getRawAuthority) &&
      Option(uri.getRawPath).exists(_.matches("(?i)/dpd_pm/[0-9]+\\.pdf")) &&
      uri.getRawQuery == null && uri.getFragment == null, "Unexpected URL in Health Canada's monograph field")
    uri

  private def lookup(html: String, din: String): Option[(URI, Option[String])] =
    val rows = Jsoup.parse(html).select("div.row").asScala.toVector
    def fields(label: String) = rows.filter { row =>
      val first = row.children().first()
      first != null && first.text().stripSuffix(":").trim.equalsIgnoreCase(label)
    }
    val dinRows = fields("DIN")
    require(dinRows.size == 1, "Cannot identify the DIN field on the Health Canada product page")
    val dinText = dinRows.head.children().asScala.drop(1).map(_.text()).mkString(" ")
    require(dinText.takeWhile(_.isDigit) == din, s"Health Canada product page does not match DIN $din")
    val documentRows = fields("Product Monograph/Veterinary Labelling")
    if documentRows.isEmpty && dinText.toLowerCase(java.util.Locale.ROOT).contains("electronic product monograph is not available")
    then None
    else
      require(documentRows.size == 1, "Cannot identify the product monograph field on the Health Canada product page")
      val row = documentRows.head
      val links = row.select("a[href]").asScala.map(_.attr("href")).distinct
      require(links.size == 1, "Expected one document link in Health Canada's monograph field")
      val revision = "(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])".r.findFirstIn(row.text())
      Some(pdfAddress(links.head) -> revision)

  private[lab] def download(uri: URI, limit: Long, out: OutputStream): Unit =
    def receive[A](read: => A): A =
      try read
      catch
        case e: javax.net.ssl.SSLHandshakeException => throw e
        case e: IOException => throw MonographNetworkFailure(uri, s"Health Canada request failed ($uri): ${e.getMessage}", e)
    val conn = uri.toURL.openConnection().asInstanceOf[HttpURLConnection]
    try
      conn.setConnectTimeout(10000)
      conn.setReadTimeout(25000)
      conn.setInstanceFollowRedirects(false)
      val status = receive(conn.getResponseCode)
      if status == 429 || (status >= 500 && status <= 599) then
        throw MonographNetworkFailure(uri, s"Health Canada returned HTTP $status for $uri")
      if status != 200 then throw IOException(s"Health Canada returned HTTP $status for $uri")
      val expected = conn.getContentLengthLong
      if expected > limit then throw IOException(s"Health Canada response exceeds $limit bytes for $uri")
      val length = Using.resource(receive(conn.getInputStream)) { input =>
        val buffer = new Array[Byte](16384)
        var total = 0L
        var n = receive(input.read(buffer))
        while n != -1 do
          total += n
          if total > limit then throw IOException(s"Health Canada response exceeds $limit bytes for $uri")
          out.write(buffer, 0, n)
          n = receive(input.read(buffer))
        total
      }
      if length == 0 || (expected >= 0 && length != expected) then throw IOException(s"Incomplete response from $uri")
    finally conn.disconnect()
