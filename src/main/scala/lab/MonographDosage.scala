package lab

import java.io.StringWriter
import java.nio.file.Path
import org.apache.pdfbox.Loader
import org.apache.pdfbox.pdmodel.PDPage
import org.apache.pdfbox.text.PDFTextStripper
import scala.util.Using

/** Locate the professional section in English PDFs, including older unnumbered headings. */
object MonographDosage:
  private val heading = "(?i)^\\s*(?:4[.)]?\\s+)?dosage\\s+(?:and|&)\\s+administration\\s*:?\\s*$".r
  private val contents = "(?i)^\\s*table\\s+of\\s+contents\\s*$".r
  private val nextSection = "^(?:(?:[5-9]|[1-9]\\d)[.)]?\\s+[A-Z][A-Z &,/()-]+|(?i:(?:[5-9][.)]?\\s+)?(?:overdosage|overdose|contraindications|warnings and precautions|action and clinical pharmacology|storage and stability)))\\s*:?$".r

  def page(path: Path): Option[Int] = readSection(path)((_, _) => false)

  /** Visit physical pages starting at the actual section heading, omitting material before
    * and after that section. A visitor can stop text extraction once it has enough pages.
    */
  private[lab] def readSection(path: Path)(visit: (Int, Vector[String]) => Boolean): Option[Int] =
    Using.resource(Loader.loadPDF(path.toFile)) { pdf =>
      val text = new StringWriter()
      var found = Option.empty[Int]
      var scanning = true
      val stripper = new PDFTextStripper():
        override def processPage(page: PDPage): Unit =
          if scanning then
            text.getBuffer.setLength(0)
            super.processPage(page)
            val lines = text.toString.replace('\u00a0', ' ').linesIterator.map(_.trim).toVector
            val start = if found.nonEmpty then 0 else if lines.exists(contents.matches) then -1 else lines.indexWhere(heading.matches)
            if start >= 0 then
              val body = if found.nonEmpty then lines else lines.drop(start + 1)
              if found.isEmpty then found = Some(getCurrentPageNo)
              val sectionEnd = body.indexWhere(nextSection.matches)
              val sectionLines = if sectionEnd >= 0 then body.take(sectionEnd) else body
              scanning = visit(getCurrentPageNo, sectionLines) && sectionEnd < 0
      stripper.writeText(pdf, text)
      found
    }
