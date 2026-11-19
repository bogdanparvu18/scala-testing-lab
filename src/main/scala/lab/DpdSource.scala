package lab

import java.io.IOException
import java.net.{HttpURLConnection, URI}
import java.nio.channels.FileChannel
import java.nio.file.{Files, Path, StandardCopyOption, StandardOpenOption}
import java.util.concurrent.{Semaphore as JavaSemaphore}
import scala.util.Using
import zio.*

private[lab] final case class DpdSource(archive: Path, origin: String)

private[lab] object DpdSource:
  val marketedUrl = URI.create("https://www.canada.ca/content/dam/hc-sc/documents/services/drug-product-database/allfiles.zip")
  private val projectArchive = Path.of("data", "allfiles.zip")

  // FileChannel locks coordinate CLI processes, but overlapping locks in one JVM throw
  // rather than wait. Keep one default download/import active per JVM as well.
  private val downloadPermit = new JavaSemaphore(1, true)

  def prepare(local: Option[Path], url: URI = marketedUrl, destination: Path = projectArchive): ZIO[Scope, Throwable, DpdSource] =
    local match
      case Some(file) =>
        // The caller owns this file; take an immutable snapshot for this import.
        for
          temp <- ZIO.acquireRelease(ZIO.attemptBlocking(Files.createTempFile("dpd-local-", ".zip")))(
            path => ZIO.attemptBlocking(Files.deleteIfExists(path)).orDie)
          _ <- ZIO.attemptBlocking(Files.copy(file, temp, StandardCopyOption.REPLACE_EXISTING))
        yield DpdSource(temp, file.toAbsolutePath.normalize().toUri.toString)
      case None => repositoryArchive(url, destination, reuse = false)

  def setup(url: URI = marketedUrl, destination: Path = projectArchive): ZIO[Scope, Throwable, DpdSource] =
    repositoryArchive(url, destination, reuse = true)

  private def repositoryArchive(url: URI, destination: Path, reuse: Boolean): ZIO[Scope, Throwable, DpdSource] =
    val target = destination.toAbsolutePath.normalize()
    val directory = target.getParent
    def downloadFailure(error: Throwable): IOException = IOException(
      s"Health Canada DPD download failed ($url -> $target): ${error.getMessage}. PostgreSQL import was not started.", error)

    val acquireLock = (for
      _ <- ZIO.acquireRelease(ZIO.attemptBlocking(downloadPermit.acquire()))(_ => ZIO.succeed(downloadPermit.release()))
      _ <- ZIO.attemptBlocking(Files.createDirectories(directory))
      // Closing the channel releases the lock after the caller's import finishes.
      // Keep the sidecar on disk so every process locks the same file.
      channel <- ZIO.acquireRelease(ZIO.attemptBlocking(FileChannel.open(
        directory.resolve(s".${target.getFileName}.lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE)))(
        channel => ZIO.attemptBlocking(channel.close()).orDie)
      _ <- ZIO.attemptBlocking(channel.lock())
    yield ()).mapError { error =>
      if reuse then IOException(
        s"Cannot prepare the Health Canada DPD archive at $target: ${error.getMessage}. PostgreSQL import was not started.", error)
      else downloadFailure(error)
    }

    acquireLock *> ZIO.attemptBlocking(reuse && !Files.notExists(target)).flatMap { cached =>
      if cached then
        ZIO.attemptBlocking {
          validate(target)
          DpdSource(target, target.toUri.toString)
        }.mapError(error => IOException(
          s"Cannot use cached Health Canada DPD archive at $target: ${error.getMessage}. " +
          """Run sbt "run import-dpd" to download a fresh copy. PostgreSQL import was not started.""", error))
      else
        ZIO.attemptBlocking {
          val part = Files.createTempFile(directory, s".${target.getFileName}-", ".part")
          try
            download(url, part)
            validate(part)
            Files.move(part, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            DpdSource(target, url.toString)
          finally Files.deleteIfExists(part)
        }.mapError(downloadFailure)
    }

  private def validate(path: Path): Unit =
    try DpdArchive.read(path)((_, _) => ())
    catch case scala.util.control.NonFatal(error) =>
      throw IOException(s"Invalid DPD ZIP: ${error.getMessage}", error)

  private def download(url: URI, target: Path): Unit =
    val connection = url.toURL.openConnection().asInstanceOf[HttpURLConnection]
    try
      connection.setConnectTimeout(15000)
      connection.setReadTimeout(60000)
      connection.setInstanceFollowRedirects(false)
      val status = connection.getResponseCode
      if status != HttpURLConnection.HTTP_OK then
        throw IOException(s"HTTP $status")
      val bytes = Using.resource(connection.getInputStream) { input =>
        Files.copy(input, target, StandardCopyOption.REPLACE_EXISTING)
      }
      val expected = connection.getContentLengthLong
      if bytes == 0 || (expected >= 0 && bytes != expected) then
        throw IOException(s"Incomplete download: received $bytes bytes (Content-Length $expected)")
    finally connection.disconnect()
