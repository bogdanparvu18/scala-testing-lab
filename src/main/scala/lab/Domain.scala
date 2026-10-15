package lab

import zio.json.*
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale

@jsonNoExtraFields
final case class Position(line: Int, character: Int, offset: Int) derives JsonCodec
@jsonNoExtraFields
final case class SourceLocation(uri: String, start: Position, end: Position, text: String) derives JsonCodec
@jsonNoExtraFields
final case class DocumentSource(uri: String, text: String) derives JsonCodec
@jsonNoExtraFields
final case class Dose(amount: BigDecimal, unit: String) derives JsonCodec
@jsonNoExtraFields
final case class Mention(
  id: String, originalText: String, role: String, source: SourceLocation,
  dose: Dose, route: String, frequency: String, patientRef: String, orderId: String,
  productStrength: Option[String] = None, doseForm: Option[String] = None
) derives JsonCodec
@jsonNoExtraFields
final case class AstRequest(
  schemaVersion: String, policyVersion: String, terminologyRelease: String,
  document: DocumentSource, mentions: Vector[Mention]
) derives JsonCodec

final case class ConceptRef(system: String, rxcui: String, release: String, display: String, tty: String) derives JsonCodec
final case class MatchEvidence(rxaui: String, text: String, tty: String, sab: String) derives JsonCodec
final case class RelationshipEvidence(source: String, target: String, rela: String, rui: String) derives JsonCodec
final case class IngredientEvidence(concept: ConceptRef, path: Vector[RelationshipEvidence]) derives JsonCodec
final case class Candidate(concept: ConceptRef, names: Vector[MatchEvidence]) derives JsonCodec
final case class LookupReport(
  query: String, terminologyRelease: String, terminologyScope: String, snapshotFingerprint: String,
  status: String, candidates: Vector[Candidate]
) derives JsonCodec
final case class Resolution(
  mention: Mention, status: String, initialConcept: Option[ConceptRef], selectedProduct: Option[ConceptRef],
  ingredients: Vector[IngredientEvidence], candidates: Vector[Candidate], matchMethod: String,
  diagnostics: Vector[String], clinicianConfirmed: Boolean = false
) derives JsonCodec
final case class SharedIngredient(patientRef: String, orderIds: Vector[String], ingredient: ConceptRef, message: String) derives JsonCodec
final case class ResolutionReport(
  schemaVersion: String, policyVersion: String, terminologyRelease: String, snapshotFingerprint: String,
  terminologyScope: String, inputSha256: String, resolutions: Vector[Resolution], sharedIngredients: Vector[SharedIngredient]
) derives JsonCodec

object TextKey:
  // No spell correction, punctuation deletion, dosage parsing, or cross-concept aliasing.
  def normalize(s: String): String = Normalizer.normalize(s, Normalizer.Form.NFKC)
    .trim.replaceAll("\\s+", " ").toLowerCase(Locale.ROOT)

object Hashing:
  def sha256(s: String): String = MessageDigest.getInstance("SHA-256")
    .digest(s.getBytes(StandardCharsets.UTF_8)).map(b => f"${b & 0xff}%02x").mkString
  def fingerprint(s: RxSnapshot): String = sha256(
    s.release + "\n" + s.scope + "\n" + s.sha256.toVector.sortBy(_._1).map((k,v) => s"$k=$v").mkString("\n")
  )

object InputValidation:
  private val units = Set("mg", "mcg", "g", "ml", "puff", "unit")
  private val routes = Set("PO", "IV", "IM", "SC", "PR", "SL", "BUCC")
  private val frequencies = Set("QD", "BID", "TID", "QID", "PRN", "Q4H", "Q6H", "Q8H", "Q12H", "Q24H")
  def validate(a: AstRequest): Unit =
    require(a.schemaVersion == "1", "Unsupported schemaVersion")
    require(a.policyVersion == "exact-v1", "Unsupported policyVersion")
    require(a.terminologyRelease.matches("[A-Za-z0-9][A-Za-z0-9._-]{0,79}"), "Invalid terminologyRelease")
    require(a.mentions.nonEmpty, "No medication mentions")
    require(a.mentions.map(_.id).distinct.size == a.mentions.size, "Duplicate mention IDs")
    require(a.mentions.map(_.orderId).distinct.size == a.mentions.size, "Duplicate order IDs")
    def positionValid(p: Position): Boolean =
      if p.offset < 0 || p.offset > a.document.text.length || p.line < 0 || p.character < 0 then false
      else
        val prefix = a.document.text.substring(0, p.offset)
        val line = prefix.count(_ == '\n')
        val lastBreak = prefix.lastIndexOf('\n')
        line == p.line && prefix.length - lastBreak - 1 == p.character
    a.mentions.foreach { m =>
      require(m.id.nonEmpty && m.orderId.nonEmpty && m.patientRef.nonEmpty, "Missing mention/order/patient reference")
      require(m.originalText.trim.nonEmpty, "Empty medication name")
      require(Set("medication", "activeIngredient", "medicationProduct")(m.role), "Unknown semantic role")
      require(m.dose.amount > 0 && units(m.dose.unit), "Invalid administered dose representation")
      require(routes(m.route) && frequencies(m.frequency), "Unsupported route or frequency")
      require(m.source.uri == a.document.uri, "Source URI mismatch")
      require(positionValid(m.source.start) && positionValid(m.source.end), "Invalid UTF-16 source positions")
      require(m.source.start.offset <= m.source.end.offset, "Reversed source range")
      require(a.document.text.substring(m.source.start.offset, m.source.end.offset) == m.source.text, "Source text mismatch")
      require(m.source.text.contains(m.originalText), "Medication mention missing from source range")
    }
