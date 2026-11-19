package lab

import java.io.IOException
import scala.io.Source
import scala.util.Using
import zio.*

object MonographSync:
  private def sharedProducts: Task[Map[(Int, String), MonographDocument]] = ZIO.attemptBlocking {
    Using.resource(Source.fromResource("monographs.tsv")(scala.io.Codec.UTF8)) { source =>
      source.getLines().filterNot(line => line.isBlank || line.startsWith("#")).map { line =>
        line.split("\t", -1) match
          case Array(code, din, url, date, hash, name) if code.matches("[1-9][0-9]{0,9}") && din.matches("[0-9]{8}") &&
              hash.matches("[0-9a-f]{64}") && name.nonEmpty =>
            (code.toInt, din) -> MonographDocument(url, Some(java.time.LocalDate.parse(date).toString), hash)
          case _ => throw IOException("Invalid row in the shared Canadian monograph index: " + line)
      }.toMap
    }
  }

  def run: Task[Unit] =
    val cache = new MonographCache()
    for
      shared <- sharedProducts
      local <- cache.indexedProducts
      products = (shared.keysIterator ++ local).toVector.distinct.sorted
      _ <- Console.printLine(s"Checking official monographs for ${products.size} Canadian presentations.")
      failures <- ZIO.foreach(products) { (code, din) =>
        val refresh = cache.resolve(code, din, refresh = true).catchSome {
          case e: MonographNetworkFailure if e.uri.getHost == "health-products.canada.ca" && shared.contains((code, din)) =>
            Console.printLineError(s"DIN $din: live DPD page unavailable (${e.getMessage}). " +
              "Using the last locally verified copy or the revision pinned in the shared index.") *>
              cache.restoreShared(code, din, shared((code, din)))
        }
        refresh.foldZIO(
          error => cache.cached(code, din).flatMap {
            case Some(saved) =>
              Console.printLineError(s"DIN $din: refresh failed (${error.getMessage}). Keeping ${saved.path}.").as(None)
            case None =>
              cache.knownUnavailable(code, din).flatMap {
                case true => Console.printLineError(
                  s"DIN $din: recheck failed (${error.getMessage}). Last official status: no electronic monograph.").as(None)
                case false => Console.printLineError(s"DIN $din: monograph download failed (${error.getMessage}).").as(Some(din))
              }
          },
          {
            case Some(saved) => Console.printLine(s"DIN $din: ${saved.path}").as(None)
            case None => Console.printLine(s"DIN $din: Health Canada lists no electronic monograph.").as(None)
          })
      }
      missing = failures.flatten
      _ <- ZIO.when(missing.nonEmpty)(ZIO.fail(IOException(
        s"Could not obtain required monographs for DIN(s) ${missing.mkString(", ")}. Retry setup or run sync-monographs.")))
    yield ()
