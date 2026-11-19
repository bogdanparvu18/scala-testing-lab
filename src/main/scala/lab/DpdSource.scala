package lab

import java.io.IOException
import java.net.{HttpURLConnection, URI}
import java.nio.file.{Files, Path, StandardCopyOption}
import scala.util.Using
import zio.*

/** A private snapshot keeps the bytes used for hashing and parsing identical. */
private[lab] final case class DpdSource(archive: Path, origin: String)

private[lab] object DpdSource:
  val marketedUrl = URI.create("https://www.canada.ca/content/dam/hc-sc/documents/services/drug-product-database/allfiles.zip")

  def prepare(local: Option[Path], url: URI = marketedUrl): ZIO[Scope, Throwable, DpdSource] =
    for
      temp <- ZIO.acquireRelease(ZIO.attemptBlocking(Files.createTempFile("dpd-marketed-", ".zip")))(
        path => ZIO.attemptBlocking(Files.deleteIfExists(path)).orDie)
      source <- ZIO.attemptBlocking {
        local match
          case Some(file) =>
            Files.copy(file, temp, StandardCopyOption.REPLACE_EXISTING)
            DpdSource(temp, file.toAbsolutePath.normalize().toUri.toString)
          case None =>
            download(url, temp)
            DpdSource(temp, url.toString)
      }
    yield source

  private def download(url: URI, target: Path): Unit =
    val connection = url.toURL.openConnection().asInstanceOf[HttpURLConnection]
    try
      connection.setConnectTimeout(15000)
      connection.setReadTimeout(60000)
      connection.setInstanceFollowRedirects(false)
      val status = connection.getResponseCode
      if status != HttpURLConnection.HTTP_OK then
        throw IOException(s"Health Canada DPD download returned HTTP $status ($url)")
      val bytes = Using.resource(connection.getInputStream) { input =>
        Files.copy(input, target, StandardCopyOption.REPLACE_EXISTING)
      }
      val expected = connection.getContentLengthLong
      if bytes == 0 || (expected >= 0 && bytes != expected) then
        throw IOException(s"Incomplete Health Canada DPD download: received $bytes bytes (Content-Length $expected)")
    finally connection.disconnect()
