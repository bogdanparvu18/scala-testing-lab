package lab

import java.nio.file.{Files, Path}
import org.apache.pdfbox.pdmodel.{PDDocument, PDPage, PDPageContentStream}
import org.apache.pdfbox.pdmodel.font.{PDType1Font, Standard14Fonts}
import scala.util.Using
import zio.*
import zio.test.*

object MonographDosageSpec extends ZIOSpecDefault:
  private def read[A](pages: Seq[String])(f: Path => A): Task[A] = ZIO.attemptBlocking {
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
      f(path)
    finally Files.deleteIfExists(path)
  }

  private def locate(pages: String*): Task[Option[Int]] = read(pages)(MonographDosage.page)

  private val product = CanadianProduct("00000001", 1, "Example", Vector("EXAMPLE 20 MG"), Vector("TABLET"), Vector("ORAL"))
  private val group = "4 DOSAGE AND ADMINISTRATION\nImmediate Release:\nAdults and children 15 years of age and older\n"
  private val explicit = "20 mg tablet/caplet: 20 mg to 40 mg every 6 to 8 hours, as required,\nnot to exceed 80 mg per day."
  private def inspect(text: String, selected: CanadianProduct = product): Task[Vector[RegimenSuggestion]] =
    read(Seq(text))(MonographRegimen.inspect(_, selected)._2)

  def spec = suite("Professional monograph dosage section")(
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
    },
    test("extracts the explicit written amount and retains the interval, PRN, limits and age group") {
      val source = group + "10 mg tablet: 10 mg once daily.\n" + explicit
      for result <- read(Seq("TABLE OF CONTENTS\n4 DOSAGE AND ADMINISTRATION", source))(MonographRegimen.inspect(_, product))
      yield assertTrue(result._1.contains(2), result._2 == Vector(RegimenSuggestion("20 mg", "q6-8h PRN", 2,
        "Immediate Release · Adults and children 15 years of age and older", explicit.replace("\n", " "))))
    },
    test("matches product strength and form independently of dose, includes limits in separate paragraphs") {
      val fixed = group + "20 mg tablet: 40 mg every 12 hours.\n\nDo not exceed 80 mg per day."
      for
        candidate <- inspect(fixed)
        otherStrength <- inspect(fixed, product.copy(ingredients = Vector("EXAMPLE 40 MG")))
        wrongForm <- inspect(fixed, product.copy(forms = Vector("CAPSULE")))
        modifiedRelease <- inspect(fixed, product.copy(forms = Vector("TABLET (DELAYED-RELEASE)")))
        combination <- inspect(fixed, product.copy(ingredients = Vector("EXAMPLE 20 MG", "OTHER 1 MG")))
      yield assertTrue(candidate.map(_.dose) == Vector("40 mg"), candidate.forall(_.evidence.endsWith("80 mg per day.")),
        otherStrength.isEmpty, wrongForm.isEmpty, modifiedRelease.isEmpty, combination.isEmpty)
    },
    test("unknown, conditional, competing, or indication-specific rules never yield a default draft") {
      val rows = Vector(
        explicit + "\n20 mg tablet: 40 mg once daily.",
        explicit + "\n20 mg tablet: consult physician before increasing.",
        explicit + "\n20 mg tablet for migraine: consult physician before increasing.",
        explicit + "\n\nIf symptoms persist take an extra dose.",
        explicit + "\n\nThe dose must be reduced in certain patients.",
        "20 mg tablet: 20 mg every 4 to 4 hours.",
        "20 mg tablet: 20 mg once daily, not to exceed 80 mg per day unless a physician directs.",
        "20 mg tablet: 5 mg/kg once daily.",
        "20 mg tablet: 20 mg once daily then 40 mg after one week.",
        "20 mg tablet: take one as directed."
      )
      for
        rejected <- ZIO.foreach(rows)(row => inspect(group + row))
        restricted <- inspect(group.replace("Immediate Release:", "Hepatic impairment\nImmediate Release:") + explicit)
        later <- inspect("4 DOSAGE AND ADMINISTRATION\n5 OVERDOSAGE\n" + group.dropWhile(_ != '\n') + explicit)
        continued <- read(Seq(group + explicit, "The dose must be reduced in certain patients."))(MonographRegimen.inspect(_, product))
        dailyPrn <- inspect(group + "20 mg tablet: 20 mg once daily as needed.")
      yield assertTrue(rejected.forall(_.isEmpty), restricted.isEmpty, later.isEmpty, continued._2.isEmpty, dailyPrn.map(_.frequency) == Vector("q24h PRN"))
    })
