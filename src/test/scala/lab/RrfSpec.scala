package lab

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, StandardOpenOption}
import scala.jdk.CollectionConverters.*
import zio.*
import zio.test.*

/** Synthetic miniature RRF records, never presented as an official NLM release. */
object RrfSpec extends ZIOSpecDefault:
  private def rrf(size: Int, cells: (Int, String)*): String =
    val fields = Array.fill(size)("")
    cells.foreach { case (i, value) => fields(i) = value }
    fields.mkString("", "|", "|")

  private def conso(id: String, tty: String, name: String, atom: String, suppress: String = "N", sab: String = "RXNORM", lang: String = "ENG"): String =
    rrf(18, 0 -> id, 1 -> lang, 7 -> atom, 11 -> sab, 12 -> tty, 13 -> id, 14 -> name, 16 -> suppress)

  private def rel(source: String, target: String, label: String, id: String, suppress: String = "", stype: String = "CUI", sab: String = "RXNORM"): String =
    rrf(16, 0 -> target, 2 -> stype, 3 -> "RO", 4 -> source, 6 -> stype, 7 -> label, 8 -> id, 10 -> sab, 14 -> suppress)

  private val names = Vector(
    conso("161", "IN", "acetaminophen", "1"),
    conso("161", "PT", "paracetamol", "2", sab = "TEST_SOURCE"),
    conso("161", "SY", "PARACETAMOL", "3", sab = "SECOND_TEST_SOURCE"),
    conso("200", "IN", "independent test ingredient", "4"),
    conso("201", "PIN", "test ingredient salt", "5"),
    conso("300", "SCDC", "test component A", "6"),
    conso("301", "SCDC", "test component B", "7"),
    conso("400", "SCD", "test combination product", "8"),
    conso("401", "SBD", "test branded product", "9"),
    conso("500", "BN", "Test Brand", "10"),
    conso("600", "DF", "Test Form", "11"),
    conso("700", "IN", "unrelated ingredient with no graph edges", "12"),
    conso("800", "IN", "inactive ingredient", "13", suppress = "O"),
    conso("800", "PT", "source term for inactive ingredient", "14", sab = "TEST_SOURCE"),
    conso("900", "PT", "source-only unmapped concept", "15", sab = "TEST_SOURCE"),
    conso("161", "PT", "obsolete source name", "16", suppress = "O", sab = "TEST_SOURCE"),
    conso("161", "PT", "editor-suppressed source name", "17", suppress = "Y", sab = "TEST_SOURCE"),
    conso("161", "PT", "non-English source name", "18", sab = "TEST_SOURCE", lang = "FRE"),
    conso("161", "PT", "unattributed source name", "19", sab = ""),
    conso("161", "PT", "unquantified suppressed source name", "20", suppress = "E", sab = "TEST_SOURCE")
  )
  private val relationships = Vector(
    rel("300", "161", "has_ingredient", "1"),
    rel("301", "201", "has_precise_ingredient", "2", suppress = "N"),
    rel("201", "200", "form_of", "3"),
    rel("400", "300", "consists_of", "4"),
    rel("400", "301", "consists_of", "5"),
    rel("401", "400", "tradename_of", "6"),
    rel("401", "500", "has_ingredient", "7"),
    rel("400", "600", "has_dose_form", "8"),
    rel("161", "999999", "related_to", "9"),
    rel("161", "800", "related_to", "10"),
    rel("161", "200", "related_to", "11", suppress = "Y"),
    rel("161", "200", "related_to", "12", stype = "AUI"),
    rel("161", "200", "related_to", "13", sab = "TEST_SOURCE")
  )

  private def withFixture[A](ns: Vector[String] = names, rs: Vector[String] = relationships)(run: Path => A): Task[A] =
    ZIO.acquireReleaseWith(ZIO.attempt(Files.createTempDirectory("rxnorm-full-rrf-test-"))) { dir =>
      ZIO.attempt {
        val paths = Files.walk(dir)
        try paths.iterator().asScala.toVector.sortBy(_.getNameCount).reverse.foreach(Files.delete)
        finally paths.close()
      }.orDie
    } { dir =>
      ZIO.attemptBlocking {
        Files.writeString(dir.resolve("RXNCONSO.RRF"), ns.mkString("", "\n", "\n"), StandardCharsets.UTF_8)
        Files.writeString(dir.resolve("RXNREL.RRF"), rs.mkString("", "\n", "\n"), StandardCharsets.UTF_8)
        // RXNSAT intentionally does not exist: this lexical resolver does not use attributes.
        run(dir)
      }
    }

  private def descriptions(p: PreparedRrf): Vector[RxDescription] =
    val builder = Vector.newBuilder[RxDescription]
    p.foreachDescription(d => { builder += d; () })
    builder.result()

  private def relations(p: PreparedRrf): Vector[RxRelation] =
    val builder = Vector.newBuilder[RxRelation]
    p.foreachRelation(r => { builder += r; () })
    builder.result()

  def spec = suite("Rrf full offline index")(
    test("imports paracetamol from source atoms joined to canonical IN161 without a manual mapping") {
      withFixture() { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        val matches = descriptions(prepared).filter(_.normalized == Rrf.normalize("paracetamol"))
        assertTrue(
          matches.map(_.rxcui).toSet == Set("161"),
          matches.map(_.sab).toSet == Set("TEST_SOURCE", "SECOND_TEST_SOURCE"),
          matches.map(_.tty).toSet == Set("PT", "SY"),
          prepared.concepts.find(_.rxcui == "161").contains(RxConcept("161", "IN", "acetaminophen"))
        )
      }
    },
    test("imports every supported active normal form independently of the example drug") {
      withFixture() { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        val noAttributesFile = !Files.exists(dir.resolve("RXNSAT.RRF"))
        assertTrue(
          prepared.concepts.exists(_.rxcui == "700"),
          prepared.concepts.exists(_.rxcui == "200"),
          prepared.concepts.size == 10,
          Rrf.scope == "all-active-rxnorm-pg-v4",
          prepared.sha256.keySet == Set("RXNCONSO.RRF", "RXNREL.RRF"),
          prepared.sha256.values.forall(_.matches("[a-f0-9]{64}")),
          noAttributesFile
        )
      }
    },
    test("preserves multiple dose-form entry terms without treating them as conflicting canonical normal forms") {
      val entryTerms = Vector(
        conso("4230", "ET", "synthetic eye drops", "21"),
        conso("4230", "ET", "synthetic ophthalmic drops", "22"),
        conso("950", "ET", "another synthetic entry term", "23")
      )
      withFixture(ns = names ++ entryTerms) { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        val raw = Vector.newBuilder[Vector[String]]
        prepared.foreachConsoRow(row => { raw += row.toVector; () })
        val retained = descriptions(prepared)
        assertTrue(
          !Rrf.canonicalTypes.contains("ET"),
          prepared.concepts.size == 10,
          !prepared.concepts.exists(c => Set("4230", "950").contains(c.rxcui)),
          raw.result().takeRight(3).map(_(14)) == Vector("synthetic eye drops", "synthetic ophthalmic drops", "another synthetic entry term"),
          !retained.exists(d => Set("21", "22", "23").contains(d.rxaui))
        )
      }
    },
    test("retains all active synonym atoms associated with a supported canonical concept") {
      val synonyms = Vector(
        conso("161", "SY", "synthetic synonym one", "21"),
        conso("161", "SY", "synthetic synonym two", "22"),
        conso("600", "ET", "synthetic dose-form entry alias", "23")
      )
      withFixture(ns = names ++ synonyms) { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        val retained = descriptions(prepared).filter(d => Set("21", "22", "23").contains(d.rxaui))
        assertTrue(
          prepared.concepts.find(_.rxcui == "161").contains(RxConcept("161", "IN", "acetaminophen")),
          prepared.concepts.find(_.rxcui == "600").contains(RxConcept("600", "DF", "Test Form")),
          retained.map(_.text).toSet == Set("synthetic synonym one", "synthetic synonym two", "synthetic dose-form entry alias"),
          retained.forall(_.sab == "RXNORM"),
          retained.map(_.tty).toSet == Set("SY", "ET")
        )
      }
    },
    test("raw streams preserve every row, empty field, quote and backslash without CSV interpretation") {
      val literalName = "synthetic \"quoted\" \\N\\t\tname"
      val rawName = conso("900", "PT", literalName, "21", suppress = "O", sab = "TEST_SOURCE")
      val rawEdge = rrf(16, 0 -> "900", 2 -> "AUI", 4 -> "800", 6 -> "AUI", 7 -> "test_relation", 10 -> "TEST_SOURCE", 12 -> "group\\1", 13 -> "Y", 14 -> "O")
      withFixture(ns = names :+ rawName, rs = relationships :+ rawEdge) { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        val consoRows = Vector.newBuilder[Vector[String]]
        val relRows = Vector.newBuilder[Vector[String]]
        prepared.foreachConsoRow(row => { consoRows += row.toVector; () })
        prepared.foreachRelRow(row => { relRows += row.toVector; () })
        val allNames = consoRows.result()
        val allEdges = relRows.result()
        assertTrue(
          allNames.size == names.size + 1,
          allNames.forall(_.size == 18),
          allNames.last(14) == literalName,
          allNames.last(2) == "",
          allNames.last(16) == "O",
          allEdges.size == relationships.size + 1,
          allEdges.forall(_.size == 16),
          allEdges.last(12) == "group\\1",
          allEdges.last(13) == "Y",
          allEdges.last(15) == ""
        )
      }
    },
    test("raw streaming verifies each source hash after the last callback") {
      withFixture() { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        Files.writeString(dir.resolve("RXNCONSO.RRF"), conso("161", "PT", "late name", "21", sab = "TEST_SOURCE") + "\n", StandardCharsets.UTF_8, StandardOpenOption.APPEND)
        Files.writeString(dir.resolve("RXNREL.RRF"), rel("161", "200", "related_to", "14") + "\n", StandardCharsets.UTF_8, StandardOpenOption.APPEND)
        val consoResult = scala.util.Try(prepared.foreachConsoRow(_ => ()))
        val relResult = scala.util.Try(prepared.foreachRelRow(_ => ()))
        assertTrue(
          consoResult.isFailure,
          relResult.isFailure,
          consoResult.failed.get.getMessage.contains("changed since preparation"),
          relResult.failed.get.getMessage.contains("changed since preparation")
        )
      }
    },
    test("uses only supplied terminology evidence and indexes synonyms for unrelated concepts") {
      val noParacetamol = names.filterNot { line =>
        Set("2", "3").contains(line.split("\\|", -1)(7))
      } :+ conso("700", "PT", "Synthetic Global Synonym", "21", sab = "TEST_SOURCE")
      withFixture(ns = noParacetamol) { dir =>
        val retained = descriptions(Rrf.prepare(dir, "2026-10-05"))
        assertTrue(
          !retained.exists(_.normalized == "paracetamol"),
          retained.filter(_.normalized == "synthetic global synonym").map(_.rxcui) == Vector("700")
        )
      }
    },
    test("omits suppressed names and foreign-source-only or inactive canonical concepts") {
      withFixture() { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        val retained = descriptions(prepared)
        val ids = prepared.concepts.map(_.rxcui).toSet
        assertTrue(
          !ids.contains("800"),
          !ids.contains("900"),
          retained.forall(d => !Set("13", "14", "15", "16", "17", "18", "19", "20").contains(d.rxaui)),
          retained.size == 12
        )
      }
    },
    test("preserves lexical ambiguity instead of choosing the first concept") {
      withFixture(ns = names :+ conso("200", "PT", "paracetamol", "21", sab = "AMBIGUOUS_TEST_SOURCE")) { dir =>
        val matches = descriptions(Rrf.prepare(dir, "2026-10-05")).filter(_.normalized == "paracetamol")
        assertTrue(matches.map(_.rxcui).toSet == Set("161", "200"))
      }
    },
    test("orients raw concept relations correctly and never projects unknown endpoint nodes") {
      withFixture() { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        val retained = relations(prepared)
        val ids = prepared.concepts.map(_.rxcui).toSet
        assertTrue(
          retained.size == 8,
          retained.contains(RxRelation("300", "161", "has_ingredient", "1")),
          retained.contains(RxRelation("301", "201", "has_precise_ingredient", "2")),
          retained.contains(RxRelation("400", "301", "consists_of", "5")),
          retained.forall(r => ids.contains(r.source) && ids.contains(r.target)),
          !ids.contains("999999")
        )
      }
    },
    test("rejects malformed RRF columns even for a row that would not be imported") {
      withFixture(ns = names :+ "bad|row|") { dir =>
        val result = scala.util.Try(Rrf.prepare(dir, "2026-10-05"))
        assertTrue(result.isFailure, result.failed.get.getMessage.contains("expected 18 RRF columns"))
      }
    },
    test("rejects a combination whose second component is missing instead of retaining a partial ingredient set") {
      withFixture(rs = relationships :+ rel("400", "999999", "consists_of", "14")) { dir =>
        val result = scala.util.Try(relations(Rrf.prepare(dir, "2026-10-05")))
        assertTrue(
          result.isFailure,
          result.failed.get.getMessage.contains("incomplete composition"),
          result.failed.get.getMessage.contains("400 consists_of 999999")
        )
      }
    },
    test("rejects malformed relationship columns while streaming") {
      withFixture(rs = relationships :+ "bad|row|") { dir =>
        val result = scala.util.Try(relations(Rrf.prepare(dir, "2026-10-05")))
        assertTrue(result.isFailure, result.failed.get.getMessage.contains("expected 16 RRF columns"))
      }
    },
    test("rejects duplicate source atom IDs instead of allowing a later row to overwrite evidence") {
      withFixture(ns = names :+ conso("200", "PT", "conflicting atom", "2", sab = "TEST_SOURCE")) { dir =>
        val result = scala.util.Try(descriptions(Rrf.prepare(dir, "2026-10-05")))
        assertTrue(result.isFailure, result.failed.get.getMessage.contains("duplicate retained RXAUI"))
      }
    },
    test("rejects malformed retained atom IDs") {
      withFixture(ns = names :+ conso("161", "PT", "bad identifier", "not-numeric", sab = "TEST_SOURCE")) { dir =>
        val result = scala.util.Try(descriptions(Rrf.prepare(dir, "2026-10-05")))
        assertTrue(result.isFailure, result.failed.get.getMessage.contains("RXAUI must be a numeric identifier"))
      }
    },
    test("rejects a release whose contents change after preparation") {
      withFixture() { dir =>
        val prepared = Rrf.prepare(dir, "2026-10-05")
        Files.writeString(dir.resolve("RXNCONSO.RRF"), conso("161", "PT", "late new name", "21", sab = "TEST_SOURCE") + "\n", StandardCharsets.UTF_8, StandardOpenOption.APPEND)
        val verified = scala.util.Try(prepared.verifyUnchanged())
        val streamed = scala.util.Try(descriptions(prepared))
        assertTrue(verified.isFailure, streamed.isFailure, streamed.failed.get.getMessage.contains("changed since preparation"))
      }
    },
    test("rejects invalid release labels and conflicting normal forms") {
      withFixture(ns = names :+ conso("161", "IN", "conflicting canonical name", "21")) { dir =>
        val badDate = scala.util.Try(Rrf.prepare(dir, "2026-02-30"))
        val badCanonical = scala.util.Try(Rrf.prepare(dir, "2026-10-05"))
        assertTrue(badDate.isFailure, badCanonical.isFailure, badCanonical.failed.get.getMessage.contains("conflicting active RXNORM normal forms"))
      }
    },
    test("normalizes lexical formatting while keeping strength and brand distinctions") {
      assertTrue(
        Rrf.normalize("  ＰＡＲＡＣＥＴＡＭＯＬ\t 500 MG  ") == "paracetamol 500 mg",
        Rrf.normalize("Tylenol") != Rrf.normalize("acetaminophen"),
        Rrf.normalize("morphine sulfate") != Rrf.normalize("morphine")
      )
    }
  )
