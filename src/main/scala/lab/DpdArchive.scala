package lab

import org.apache.commons.csv.CSVFormat
import org.apache.commons.io.input.{BOMInputStream, BoundedInputStream}
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets
import java.nio.file.Path
import java.time.LocalDate
import java.time.format.{DateTimeFormatter, DateTimeFormatterBuilder, ResolverStyle}
import java.util.Locale
import java.util.zip.{CRC32, CheckedInputStream, ZipFile}
import scala.jdk.CollectionConverters.*
import scala.util.Using
import java.io.UncheckedIOException

/** Positional records in the official, headerless, marketed-product DPD extract. */
enum DpdFile(val entryName: String, val columnCount: Int):
  case Product extends DpdFile("drug.txt", 14)
  case Ingredient extends DpdFile("ingred.txt", 15)
  case Form extends DpdFile("form.txt", 4)
  case Route extends DpdFile("route.txt", 4)
  case Status extends DpdFile("status.txt", 7)

object DpdArchive:
  private val dateFormat: DateTimeFormatter = new DateTimeFormatterBuilder().parseCaseInsensitive()
    .appendPattern("dd-MMM-uuuu").toFormatter(Locale.ENGLISH).withResolverStyle(ResolverStyle.STRICT)

  def date(value: String): LocalDate = LocalDate.parse(value, dateFormat)

  /** Each file is streamed exactly once, products before dependent records.
    * The consumer must roll back if a later record or checksum fails.
    */
  def read(path: Path)(consume: (DpdFile, Vector[String]) => Unit): Unit =
    Using.resource(new ZipFile(path.toFile)) { zip =>
      val entries = zip.entries().asScala.toVector.groupBy(_.getName)
      for file <- DpdFile.values do
        val matching = entries.getOrElse(file.entryName, Vector.empty)
        require(matching.size == 1, s"Expected one ${file.entryName} in the marketed DPD extract; found ${matching.size}")
        val entry = matching.head
        require(entry.getSize > 0 && entry.getSize <= 128L * 1024 * 1024,
          s"Unexpected uncompressed size for ${file.entryName}: ${entry.getSize}")
        val crc = new CRC32
        Using.resource(new CheckedInputStream(zip.getInputStream(entry), crc)) { input =>
          val limited = BoundedInputStream.builder().setInputStream(input).setMaxCount(entry.getSize + 1).get()
          val contents = BOMInputStream.builder().setInputStream(limited).get()
          // Report invalid UTF-8, instead of replacing corrupt input with U+FFFD.
          val reader = new InputStreamReader(contents, StandardCharsets.UTF_8.newDecoder())
          Using.resource(CSVFormat.RFC4180.parse(reader)) { parser =>
            val rows = parser.iterator()
            var count = 0L
            def hasNext: Boolean =
              try rows.hasNext
              catch case error: UncheckedIOException =>
                throw IllegalArgumentException(s"${file.entryName} record ${count + 1}: invalid UTF-8 or CSV", error)
            while hasNext do
              val row = rows.next()
              count += 1
              require(row.size() == file.columnCount,
                s"${file.entryName} record $count: expected ${file.columnCount} columns, found ${row.size()}")
              consume(file, row.iterator().asScala.toVector)
            require(count > 0, s"Empty DPD extract file: ${file.entryName}")
            require(limited.getCount == entry.getSize && crc.getValue == entry.getCrc,
              s"Size or checksum mismatch in ${file.entryName}")
          }
        }
    }
