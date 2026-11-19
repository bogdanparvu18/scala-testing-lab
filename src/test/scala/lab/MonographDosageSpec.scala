package lab

import java.nio.file.Files
import org.apache.pdfbox.pdmodel.{PDDocument, PDPage, PDPageContentStream}
import org.apache.pdfbox.pdmodel.font.{PDType1Font, Standard14Fonts}
import scala.util.Using
import zio.*
import zio.test.*

object MonographDosageSpec extends ZIOSpecDefault:
  private def locate(pages: String*): Task[Option[Int]] = ZIO.attemptBlocking {
    val path = Files.createTempFile("monograph-heading-", ".pdf")
    try
      Using.resource(new PDDocument()) { doc =>
        val font = new PDType1Font(Standard14Fonts.FontName.HELVETICA)
        pages.foreach { text =>
          val page = new PDPage()
          doc.addPage(page)
          if text.nonEmpty then Using.resource(new PDPageContentStream(doc, page)) { stream =>
            stream.beginText()
            stream.setFont(font, 12)
            stream.setLeading(16)
            stream.newLineAtOffset(40, 640)
            text.linesIterator.foreach { line =>
              stream.showText(line)
              stream.newLine()
            }
            stream.endText()
          }
        }
        doc.save(path.toFile)
      }
      MonographDosage.page(path)
    finally Files.deleteIfExists(path)
  }

  def spec = suite("Official English dosage headings")(
    test("skips contents and cross-references, counts blank pages") {
      for
        found <- locate("Table of Contents\n4 DOSAGE AND ADMINISTRATION", "",
          "See Dosage and Administration for details.", "4 DOSAGE AND ADMINISTRATION\n4.1 Dosing considerations")
      yield assertTrue(found.contains(4))
    },
    test("recognizes older unnumbered headings and leaves unknown layouts for manual navigation") {
      for
        old <- locate("Dosage and Administration:")
        missing <- locate("Dosage and Administration....... 7", "")
      yield assertTrue(old.contains(1), missing.isEmpty)
    })
