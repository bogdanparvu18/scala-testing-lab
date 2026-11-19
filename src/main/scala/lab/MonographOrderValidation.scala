package lab

import zio.*
import zio.json.*

final case class MonographValidation(status: String, din: Option[String], sha256: Option[String],
    page: Option[Int], issues: Vector[RegimenViolation], context: Option[String] = None,
    evidence: Option[String] = None, rule: Option[RegimenRule] = None) derives JsonCodec

/** Check the saved Canadian selection against the same local catalog and verified
  * PDF as the editor. Never accept a rule or a source path from the submitted AST.
  */
final class MonographOrderValidation(
    candidates: (String, String) => Task[CanadianProductCandidates],
    cached: (Int, String) => Task[Option[CachedMonograph]]):
  import MonographOrderValidation.*

  // Recheck the current DIN and cached PDF checksum on every request; parsed text
  // is reusable only for that same checksum and full Canadian presentation.
  private val passages = scala.collection.mutable.LinkedHashMap.empty[
    (CanadianProduct, String), (Option[Int], Vector[RegimenSuggestion])]

  private def inspect(pdf: CachedMonograph, product: CanadianProduct): (Option[Int], Vector[RegimenSuggestion]) =
    val key = product -> pdf.sha256
    passages.synchronized(passages.get(key)).getOrElse {
      val parsed = MonographRegimen.inspect(pdf.path, product)
      passages.synchronized {
        if passages.size >= 64 then passages.remove(passages.head._1)
        passages.update(key, parsed)
      }
      parsed
    }

  def check(release: String, rxcui: String, din: String, sha256: String,
      dose: Option[Dose], frequency: Option[String]): UIO[MonographValidation] =
    val pin = Some(MonographSource(din, sha256))
    def unavailable(message: String) = unverified(pin, message)
    candidates(release, rxcui).flatMap { available =>
      available.items.filter(_.din == din) match
        case Vector(product) if available.release == release && available.rxcui == rxcui =>
          cached(product.drugCode, din).flatMap {
            case None => ZIO.succeed(unavailable(s"No verified cached PDF is available for DIN $din. Reopen its monograph."))
            case Some(pdf) if pdf.sha256 != sha256 =>
              ZIO.succeed(unavailable(s"The current PDF for DIN $din differs from the saved revision. Reopen the monograph to review the revision."))
            case Some(pdf) =>
              ZIO.attemptBlocking {
                val (page, suggestions) = inspect(pdf, product)
                suggestions match
                  case Vector(instruction) =>
                    val issues = instruction.rule.violations(dose, frequency)
                    MonographValidation(if issues.isEmpty then "withinMonograph" else "outsideMonograph",
                      Some(din), Some(sha256), Some(instruction.page), issues, Some(instruction.context),
                      Some(instruction.evidence), Some(instruction.rule))
                  case _ =>
                    unavailable(s"No unambiguous supported dose and frequency instruction was found for DIN $din. Review the PDF manually.").copy(page = page)
              }
          }
        case _ => ZIO.succeed(unavailable(s"DIN $din is not eligible for RxCUI $rxcui in release $release. Select the Canadian presentation again."))
    }.catchAll(_ => ZIO.succeed(unavailable(s"Could not verify the Canadian product and cached PDF for DIN $din. Check the local catalog and monograph cache.")))

  def validateOrders(report: ResolutionReport, requireMonograph: Boolean): UIO[ResolutionReport] =
    ZIO.foreach(report.resolutions) { resolution =>
      val mention = resolution.mention
      mention.productBinding match
        case None if requireMonograph =>
          ZIO.succeed(resolution.copy(monographValidation = Some(unverified(None,
            "Select an exact RxNorm product and Canadian monograph to check the dose and frequency."))))
        case None => ZIO.succeed(resolution)
        case Some(binding) =>
          val checked = mention.monographSource match
            case None => ZIO.succeed(unverified(None, "No Canadian monograph has been selected. Select the DIN to check the dose and frequency."))
            case pin @ Some(source) =>
              if resolution.status == "resolved" && binding.release == report.terminologyRelease &&
                  resolution.selectedProduct.exists(p => p.rxcui == binding.rxcui && p.release == binding.release) then
                check(binding.release, binding.rxcui, source.din, source.sha256, Some(mention.dose), Some(mention.frequency))
              else ZIO.succeed(unverified(pin, "Resolve the selected RxNorm product before checking its Canadian monograph."))
          checked.map(result => resolution.copy(monographValidation = Some(result)))
    }.map(results => report.copy(resolutions = results))

object MonographOrderValidation:
  private def unverified(pin: Option[MonographSource], message: String): MonographValidation =
    MonographValidation("unverified", pin.map(_.din), pin.map(_.sha256), None, Vector(RegimenViolation("source", message)))

  def blockingIssues(report: ResolutionReport, requireMonograph: Boolean): Vector[String] =
    report.resolutions.flatMap { resolution =>
      resolution.monographValidation.toVector.filter(result =>
        result.status != "withinMonograph" && (requireMonograph || resolution.mention.monographSource.nonEmpty)
      ).flatMap(_.issues.map(issue => s"${resolution.mention.id} / ${issue.field}: ${issue.message}"))
    }
