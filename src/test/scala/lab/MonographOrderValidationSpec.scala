package lab

import java.nio.file.{Files, Path}
import org.apache.pdfbox.pdmodel.{PDDocument, PDPage, PDPageContentStream}
import org.apache.pdfbox.pdmodel.font.{PDType1Font, Standard14Fonts}
import scala.util.Using
import zio.*
import zio.json.*
import zio.test.*

object MonographOrderValidationSpec extends ZIOSpecDefault:
  private val din = "00000042"
  private val release = "2026-10-05"
  private val rx = "10"
  private val product = CanadianProduct(din, 1, "Example", Vector("EXAMPLE 20 MG"), Vector("TABLET"), Vector("ORAL"))
  private val candidates = CanadianProductCandidates(release, rx, "Example tablet", Vector(product))
  private val productRef = ConceptRef("RxNorm", rx, release, "Example tablet", "SCD")
  private val position = Position(0, 0, 0)
  private val mention = Mention("Plan:M", "M", "medication", SourceLocation("file:///rx.clinical", position, position, ""),
    Dose(20, "mg"), "PO", "Q8H PRN", "Pat", "Plan", productBinding = Some(ProductBinding(rx, release)))
  private def report(item: Mention) = ResolutionReport("2", "explicit-monograph-v1", release, "hash", "scope", "input",
    Vector(Resolution(item, "resolved", Some(productRef), Some(productRef), Vector.empty, Vector.empty, "explicit_rxcui", Vector.empty)), Vector.empty)

  private def syntheticPdf(path: Path): CachedMonograph =
    Using.resource(new PDDocument()) { pdf =>
      val page = new PDPage()
      pdf.addPage(page)
      Using.resource(new PDPageContentStream(pdf, page)) { out =>
        out.beginText()
        out.setFont(new PDType1Font(Standard14Fonts.FontName.HELVETICA), 12)
        out.setLeading(16)
        out.newLineAtOffset(40, 640)
        Vector("DOSAGE AND ADMINISTRATION", "Immediate Release:", "Adults",
          "20 mg tablet: 20 mg to 40 mg every 6 to 8 hours as needed,",
          "not to exceed 80 mg per day.").foreach { line => out.showText(line); out.newLine() }
        out.endText()
      }
      pdf.save(path.toFile)
    }
    CachedMonograph(path, "https://pdf.hres.ca/dpd_pm/00000001.PDF", Rrf.hash(path), None)

  def spec = suite("Authoritative monograph validation")(
    test("the normal resolution report checks current edited fields against the selected source") {
      ZIO.scoped {
        for
          path <- ZIO.acquireRelease(ZIO.attempt(Files.createTempFile("regimen-validation-", ".pdf")))(p => ZIO.attempt(Files.deleteIfExists(p)).orDie)
          pdf <- ZIO.attempt(syntheticPdf(path))
          pin = MonographSource(din, pdf.sha256)
          order = mention.copy(monographSource = Some(pin))
          validator = new MonographOrderValidation((_, _) => ZIO.succeed(candidates), (_, _) => ZIO.some(pdf))
          valid <- validator.validateOrders(report(order.copy(dose = Dose(0.04, "g"), frequency = "Q6H PRN")), true)
          invalid <- validator.validateOrders(report(order.copy(dose = Dose(1000, "mg"), frequency = "Q6H")), false)
          wrongRevision <- validator.check(release, rx, din, "a" * 64, Some(order.dose), Some(order.frequency))
          wrongDin <- validator.check(release, rx, "00000043", pin.sha256, Some(order.dose), Some(order.frequency))
          success = valid.resolutions.head.monographValidation.get
          failure = invalid.resolutions.head.monographValidation.get
        yield assertTrue(success.status == "withinMonograph", success.page.contains(1), success.rule.flatMap(_.maxDailyMg).contains(BigDecimal(80)),
          success.context.nonEmpty, success.evidence.nonEmpty, failure.status == "outsideMonograph", failure.issues.map(_.field).toSet == Set("dose", "frequency"),
          failure.sha256.contains(pdf.sha256), MonographOrderValidation.blockingIssues(invalid, false).size == 2,
          wrongRevision.status == "unverified", wrongDin.status == "unverified", !invalid.resolutions.head.clinicianConfirmed)
      }
    },
    test("missing sources preserve legacy terminology and block strict validation, including plain-name orders") {
      val validator = new MonographOrderValidation((_, _) => ZIO.dieMessage("unexpected catalog query"), (_, _) => ZIO.dieMessage("unexpected PDF query"))
      for
        legacy <- validator.validateOrders(report(mention), false)
        named <- validator.validateOrders(report(mention.copy(productBinding = None)), false)
        strict <- validator.validateOrders(report(mention.copy(productBinding = None)), true)
      yield assertTrue(legacy.resolutions.head.monographValidation.exists(_.status == "unverified"),
        MonographOrderValidation.blockingIssues(legacy, false).isEmpty, MonographOrderValidation.blockingIssues(legacy, true).nonEmpty,
        named.resolutions.head.monographValidation.isEmpty, MonographOrderValidation.blockingIssues(strict, true).nonEmpty)
    },
    test("a cache failure is unverified and cannot become a clinical range violation") {
      val validator = new MonographOrderValidation((_, _) => ZIO.succeed(candidates), (_, _) => ZIO.fail(Exception("unavailable")))
      validator.check(release, rx, din, "a" * 64, Some(mention.dose), Some(mention.frequency)).map { result =>
        assertTrue(result.status == "unverified", result.issues.map(_.field) == Vector("source"), result.rule.isEmpty)
      }
    },
    test("schema 3 requires a valid PDF pin and explicit RxNorm binding and rejects injected rules") {
      val source = "M"
      val order = mention.copy(source = mention.source.copy(text = source, end = Position(0,1,1)), monographSource = Some(MonographSource(din, "b" * 64)))
      val ast = AstRequest("3", "explicit-monograph-v1", release, DocumentSource(order.source.uri, source), Vector(order))
      def accepts(request: AstRequest) = scala.util.Try(InputValidation.validate(request)).isSuccess
      assertTrue(accepts(ast), !accepts(ast.copy(mentions = Vector(order.copy(monographSource = None)))),
        !accepts(ast.copy(mentions = Vector(order.copy(productBinding = None)))),
        !accepts(ast.copy(schemaVersion = "2", policyVersion = "explicit-product-v1")),
        !accepts(ast.copy(mentions = Vector(order.copy(monographSource = Some(MonographSource("42", "x")))))),
        """{"din":"00000042","sha256":"abc","maxDoseMg":999}""".fromJson[MonographSource].isLeft)
    }
  )
