package lab

import java.nio.charset.StandardCharsets.UTF_8
import java.nio.file.{Files, Path}
import java.util.zip.{ZipEntry, ZipOutputStream}
import scala.util.{Try, Using}
import zio.test.*

object DpdArchiveSpec extends ZIOSpecDefault:
  private val product = Vector("42", "", "Human", "00012345", "A, \"B\" café\r\nC",
    "", "N", "", "1", "02-NOV-2026", "001", "Humain", "", "")
  private def csv(fields: Seq[String]): String =
    fields.map(s => "\"" + s.replace("\"", "\"\"") + "\"").mkString(",") + "\r\n"

  private val records = DpdFile.values.iterator.map { file =>
    val row = if file == DpdFile.Product then product else Vector.fill(file.columnCount)("")
    file -> csv(row).getBytes(UTF_8)
  }.toMap

  private def withArchive[A](contents: Map[DpdFile, Array[Byte]])(run: Path => A): A =
    val path = Files.createTempFile("dpd-test-", ".zip")
    try
      Using.resource(new ZipOutputStream(Files.newOutputStream(path))) { zip =>
        contents.foreach { (file, bytes) =>
          zip.putNextEntry(new ZipEntry(file.entryName))
          zip.write(bytes)
          zip.closeEntry()
        }
      }
      run(path)
    finally Files.deleteIfExists(path)

  def spec = suite("Health Canada DPD archive")(
    test("reads headerless UTF-8 CSV, quoted punctuation, newlines, and empty fields without changing DIN") {
      val rows = withArchive(records.updated(DpdFile.Product, ("\uFEFF" + csv(product)).getBytes(UTF_8))) { path =>
        val result = Vector.newBuilder[(DpdFile, Vector[String])]
        DpdArchive.read(path)((file, row) => result += file -> row)
        result.result()
      }
      assertTrue(rows.map(_._1) == DpdFile.values.toVector, rows.head._2 == product,
        DpdArchive.date("02-NOV-2026").toString == "2026-11-02", Try(DpdArchive.date("31-FEB-2026")).isFailure)
    },
    test("rejects missing files, incompatible widths, unclosed quotes and malformed UTF-8") {
      val cases = List(
        records - DpdFile.Status,
        records.updated(DpdFile.Status, Array.empty[Byte]),
        records.updated(DpdFile.Product, csv(product.dropRight(1)).getBytes(UTF_8)),
        records.updated(DpdFile.Form, "\"1\",\"2\",\"tablet\",\"unterminated".getBytes(UTF_8)),
        records.updated(DpdFile.Form, "\"1\",\"2\",\"".getBytes(UTF_8) ++ Array(0xff.toByte) ++ "\",\"\"".getBytes(UTF_8))
      )
      val failures = cases.map(contents => withArchive(contents)(path => Try(DpdArchive.read(path)((_, _) => ()))))
      assertTrue(failures.forall(_.isFailure))
    }
  )
