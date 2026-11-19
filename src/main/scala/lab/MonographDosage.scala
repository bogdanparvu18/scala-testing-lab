package lab

import java.io.StringWriter
import java.nio.file.Path
import org.apache.pdfbox.Loader
import org.apache.pdfbox.pdmodel.PDPage
import org.apache.pdfbox.text.PDFTextStripper
import scala.util.Using

/** Find the professional section in English PDFs, including older unnumbered headings.
  * Return a physical, one-based PDF page so the clinician can consult the complete source.
  */
object MonographDosage:
  private val heading = "(?i)^\\s*(?:4[.)]?\\s+)?(?:dosage\\s+and\\s+administration|dosage\\s*&\\s*administration)\\s*:?\\s*$".r
  private val contents = "(?i)^\\s*table\\s+of\\s+contents\\s*$".r

  def page(path: Path): Option[Int] = Using.resource(Loader.loadPDF(path.toFile)) { pdf =>
    val text = new StringWriter()
    var found = Option.empty[Int]
    val stripper = new PDFTextStripper():
      override def processPage(page: PDPage): Unit =
        if found.isEmpty then
          text.getBuffer.setLength(0)
          super.processPage(page)
          val lines = text.toString.replace('\u00a0', ' ').linesIterator.toVector
          if !lines.exists(contents.matches) && lines.exists(heading.matches) then found = Some(getCurrentPageNo)
    stripper.writeText(pdf, text)
    found
  }
