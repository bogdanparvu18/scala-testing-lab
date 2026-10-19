package lab

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path}
import java.security.MessageDigest
import java.text.Normalizer
import java.time.LocalDate
import java.util.Locale
import scala.collection.mutable
import scala.util.Using

final case class RxConcept(rxcui: String, tty: String, display: String)
final case class RxDescription(rxcui: String, rxaui: String, text: String, normalized: String, tty: String, sab: String)
final case class RxRelation(source: String, target: String, rela: String, rui: String)
final case class RxAttribute(rxcui: String, rxaui: String, atn: String, value: String, atui: String)
final case class RxSnapshot(
    release: String,
    scope: String,
    sha256: Map[String, String],
    concepts: Vector[RxConcept],
    descriptions: Vector[RxDescription],
    relations: Vector[RxRelation],
    attributes: Vector[RxAttribute]
)

/** An immutable import plan over local release files, with streamed row callbacks.
  *
  * Only canonical concept summaries are held in memory. Description streaming
  * additionally remembers numeric atom IDs to reject duplicate RXAUIs, without
  * retaining description payloads. Callbacks may persist bounded batches.
  *
  * Consumers must keep their transaction open until all streams finish and
  * verifyUnchanged succeeds. A callback can already have received records when
  * a later malformed row or changed source file makes the stream fail.
  */
final class PreparedRrf private[lab] (
    private val dir: Path,
    val release: String,
    val sha256: Map[String, String],
    val concepts: Vector[RxConcept]
):
  private val conceptTypes = concepts.iterator.map(c => c.rxcui -> c.tty).toMap
  private val conceptIds = conceptTypes.keySet

  /** Original RXNCONSO fields in official file order, including empty strings.
    * There is no CSV quoting or backslash interpretation in the RRF format.
    * The final delimiter is not an additional field. No rows are filtered here.
    */
  def foreachConsoRow(consume: Array[String] => Unit): Unit =
    Rrf.rows(dir.resolve(Rrf.namesFile), 18) { (c, _) => consume(c.take(18)) }
    verifyFile(Rrf.namesFile)

  /** Original RXNREL fields in official file order (RG precedes DIR).
    * The database COPY encoder must escape its own text format separately.
    */
  def foreachRelRow(consume: Array[String] => Unit): Unit =
    Rrf.rows(dir.resolve(Rrf.relationsFile), 16) { (c, _) => consume(c.take(16)) }
    verifyFile(Rrf.relationsFile)

  /** All active English source atoms whose RxCUI has an active RXNORM normal form.
    * Source TTY and SAB remain unchanged; a source synonym is not relabelled as
    * an RXNORM synonym. Equal strings attached to different concepts remain
    * separate candidates. Duplicate retained RXAUIs are rejected, even if their
    * payloads are identical, because RXNCONSO defines one row per atom.
    */
  def foreachDescription(consume: RxDescription => Unit): Unit =
    val atoms = mutable.LongMap.empty[Unit]
    Rrf.rows(dir.resolve(Rrf.namesFile), 18) { (c, line) =>
      if c(1) == "ENG" && c(16) == "N" && c(11).nonEmpty && conceptIds.contains(c(0)) then
        Rrf.validateName(c, line)
        val atom = c(7).toLongOption.getOrElse(Rrf.fail(s"RXNCONSO.RRF:$line: RXAUI exceeds the supported 64-bit identifier range"))
        if atoms.contains(atom) then Rrf.fail(s"RXNCONSO.RRF:$line: duplicate retained RXAUI ${c(7)}")
        atoms.update(atom, ())
        consume(RxDescription(c(0), c(7), c(14), Rrf.normalize(c(14)), c(12), c(11)))
    }
    verifyFile(Rrf.namesFile)

  /** Active RXNORM CUI-to-CUI edges with two imported canonical endpoints.
    * Duplicate raw relation rows are emitted and preserved in raw PostgreSQL
    * storage. Resolver queries may deduplicate equivalent semantic edges.
    * Atom-level edges, other source graphs and generic unknown endpoints are
    * omitted. A missing endpoint on a required ingredient-composition path
    * fails the import, preventing an apparently complete partial ingredient set.
    * No synthetic endpoint concepts or reverse edges are invented.
    */
  def foreachRelation(consume: RxRelation => Unit): Unit =
    Rrf.rows(dir.resolve(Rrf.relationsFile), 16) { (c, line) =>
      // NLM marks relationship suppression as not yet in use. Real RXNORM
      // concept relationships can use a blank flag; explicit N is also active.
      if c(10) == "RXNORM" && (c(14).isEmpty || c(14) == "N") && c(2) == "CUI" && c(6) == "CUI" then
        Rrf.validateId(c(0), s"RXNREL.RRF:$line: RXCUI1")
        Rrf.validateId(c(4), s"RXNREL.RRF:$line: RXCUI2")
        val requiredComposition = conceptTypes.get(c(4)).exists { sourceType =>
          (sourceType, c(7)) match
            case ("SBD", "tradename_of") => true
            case ("SCD" | "SBD", "consists_of") => true
            case ("SBDC", "tradename_of") => true
            case ("SCDC", "has_ingredient" | "has_precise_ingredient") => true
            case ("SCD", "has_ingredients") => true
            case ("MIN", "has_part") => true
            case ("PIN", "form_of") => true
            case _ => false
        }
        if requiredComposition && !conceptIds.contains(c(0)) then
          Rrf.fail(s"RXNREL.RRF:$line: incomplete composition: ${c(4)} ${c(7)} ${c(0)} has no imported active canonical target")
        if c(7).nonEmpty && conceptIds.contains(c(0)) && conceptIds.contains(c(4)) then
          // RXNREL states the relationship that SECOND has to FIRST.
          consume(RxRelation(c(4), c(0), c(7), c(8)))
    }
    verifyFile(Rrf.relationsFile)

  /** Must succeed immediately before the consumer activates its staged release. */
  def verifyUnchanged(): Unit = Rrf.requiredFiles.foreach(verifyFile)

  private def verifyFile(name: String): Unit =
    if Rrf.hash(dir.resolve(name)) != sha256(name) then
      Rrf.fail(s"RRF input changed since preparation: $name. Keep the import inactive and retry against an immutable extracted release.")

/** Fully offline import of original RXNCONSO/RXNREL rows and a derived active
  * normalized concept graph with an all-source English lexical index. No input term, seed RxCUI,
  * external API, or hand-authored synonym table determines what is imported.
  *
  * Scope is deliberately explicit: canonical concepts require an active English
  * RXNORM atom with a supported canonical TTY. Source-only concepts without that
  * normal form are preserved in raw tables but not indexed. Names use SUPPRESS=N; relationships accept N
  * or the documented unused blank flag. Retired/suppressed names are not aliases.
  *
  * RXNSAT is unnecessary for this resolver's lexical/relationship operations and
  * is not loaded. This importer does not claim to import every file or attribute
  * from the full release, or validate clinical dosing.
  *
  * NLM reference: https://www.nlm.nih.gov/research/umls/rxnorm/docs/techdoc.html
  * Sections 11.4, 12.4, 12.7 and 14.1. Run file I/O in ZIO.attemptBlocking.
  */
object Rrf:
  val scope = "all-active-rxnorm-pg-v4"
  private[lab] val namesFile = "RXNCONSO.RRF"
  private[lab] val relationsFile = "RXNREL.RRF"
  private[lab] val requiredFiles = Vector(namesFile, relationsFile)
  // NLM Appendix 5 separates canonical concept types from synonyms and ET.
  // ET is a dose-form entry term, not a canonical normal form. Multiple active
  // ET strings may share an RxCUI; keep them in raw rows, without inventing a
  // canonical dose form or a mapping to one. Associated names are still read
  // by foreachDescription when their RxCUI has a supported canonical atom.
  val canonicalTypes: Set[String] = Set(
    "IN", "PIN", "MIN", "BN", "SCD", "SBD", "SCDC", "SBDC", "SCDF", "SBDF",
    "SCDFP", "SBDFP", "SCDG", "SBDG", "SCDGP", "DF", "DFG", "GPCK", "BPCK"
  )

  /** Formatting normalization, not synonym or salt/strength equivalence. */
  def normalize(value: String): String =
    Normalizer.normalize(value, Normalizer.Form.NFKC)
      .trim.replaceAll("\\s+", " ").toLowerCase(Locale.ROOT)

  private[lab] def fail(message: String): Nothing = throw new IllegalArgumentException(message)

  private[lab] def validateId(value: String, field: String): Unit =
    if value.isEmpty || !value.forall(c => c >= '0' && c <= '9') then fail(s"$field must be a numeric identifier")

  private[lab] def validateName(c: Array[String], line: Long): Unit =
    validateId(c(0), s"RXNCONSO.RRF:$line: RXCUI")
    validateId(c(7), s"RXNCONSO.RRF:$line: RXAUI")
    if c(12).trim.isEmpty || c(14).trim.isEmpty then fail(s"RXNCONSO.RRF:$line: active retained atom has an empty TTY or STR")

  private[lab] def rows(path: Path, expectedColumns: Int)(consume: (Array[String], Long) => Unit): Unit =
    Using.resource(Files.newBufferedReader(path, StandardCharsets.UTF_8)) { reader =>
      var lineNumber = 0L
      var line = reader.readLine()
      while line != null do
        lineNumber += 1
        val fields = line.split("\\|", -1)
        if fields.length != expectedColumns + 1 || fields.last.nonEmpty then
          fail(s"${path.getFileName}:$lineNumber: expected $expectedColumns RRF columns and a final pipe; found ${fields.length - 1}")
        consume(fields, lineNumber)
        line = reader.readLine()
    }

  private[lab] def hash(path: Path): String =
    val digest = MessageDigest.getInstance("SHA-256")
    Using.resource(Files.newInputStream(path)) { stream =>
      val buffer = new Array[Byte](65536)
      var count = stream.read(buffer)
      while count != -1 do
        digest.update(buffer, 0, count)
        count = stream.read(buffer)
    }
    digest.digest().map(b => f"${b & 0xff}%02x").mkString

  /** Prepare a full active index. The date must come from the downloaded release;
    * it is validated as a label, while hashes identify actual file contents.
    * This method does not authenticate an archive or infer its release date.
    */
  def prepare(dir: Path, release: String): PreparedRrf =
    if !release.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}") then fail("release must be an ISO date (yyyy-MM-dd) from the RxNorm archive")
    try LocalDate.parse(release)
    catch case _: java.time.format.DateTimeParseException => fail("release must be a valid ISO date (yyyy-MM-dd)")
    requiredFiles.foreach { name =>
      if !Files.isRegularFile(dir.resolve(name)) then fail(s"Missing required RRF file: ${dir.resolve(name)}")
    }
    val hashes = requiredFiles.map(n => n -> hash(dir.resolve(n))).toMap
    val concepts = mutable.HashMap.empty[String, RxConcept]
    rows(dir.resolve(namesFile), 18) { (c, line) =>
      if c(1) == "ENG" && c(11) == "RXNORM" && c(16) == "N" && canonicalTypes.contains(c(12)) then
        validateName(c, line)
        val concept = RxConcept(c(0), c(12), c(14))
        concepts.get(concept.rxcui) match
          case Some(previous) if previous != concept =>
            fail(s"RXNCONSO.RRF:$line: conflicting active RXNORM normal forms for RxCUI ${concept.rxcui}: ${previous.tty} '${previous.display}' versus ${concept.tty} '${concept.display}' (RXAUI ${c(7)})")
          case _ => concepts(concept.rxcui) = concept
    }
    if concepts.isEmpty then fail("RXNCONSO.RRF contains no active English RXNORM normal forms in the supported scope")
    val prepared = new PreparedRrf(dir, release, hashes, concepts.values.toVector.sortBy(_.rxcui))
    prepared.verifyUnchanged()
    prepared
