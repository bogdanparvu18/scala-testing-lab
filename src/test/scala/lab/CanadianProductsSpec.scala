package lab

import lab.CanadianProducts.*
import zio.test.*

object CanadianProductsSpec extends ZIOSpecDefault:
  private val generic = RxConcept("10", "SCD", "Example 500 MG Oral Tablet")
  private val branded = RxConcept("11", "SBD", "Example 500 MG Oral Tablet [TestBrand]")
  private val ingredient = RxConcept("20", "IN", "Example")
  private val component = RxConcept("21", "SCDC", "Example 500 MG")
  private val form = RxConcept("30", "DF", "Oral Tablet")
  private val brand = RxConcept("40", "BN", "TestBrand")
  private def edge(s: String, t: String, rel: String) = RxRelation(s, t, rel, s + "-" + t)
  private val snapshot = RxSnapshot("2099-01-01", Rrf.scope, Map.empty, Vector(generic, branded, ingredient, component, form, brand),
    Vector.empty, Vector(edge("11", "10", "tradename_of"), edge("11", "40", "has_ingredient"),
      edge("11", "30", "has_dose_form"), edge("10", "30", "has_dose_form"), edge("10", "21", "consists_of"),
      edge("21", "20", "has_ingredient")), Vector(RxAttribute("21", "1", "RXN_STRENGTH", "500 MG", "A1")))
  private val canadian = Presentation("00001234", 1234, "TESTBRAND EXTRA STRENGTH", Vector("TABLET"), Vector("ORAL"))
  private val drug = Ingredient("EXAMPLE CANADIAN NAME", "500", "MG", "", "", "I", "", "N")
  private val aliases = Map("20" -> Set("example", "example canadian name"))

  def spec = suite("Canadian product candidates")(
    test("requires matching component, amount, route, dose form and whole brand tokens") {
      val signature = profile(branded, snapshot).get
      def check(p: Presentation, i: Ingredient) = candidate(signature, aliases, p, Vector(i))
      assertTrue(check(canadian, drug).exists(_.din == "00001234"),
        check(canadian.copy(brandName = "TESTBRANDX"), drug).isEmpty,
        check(canadian.copy(forms = Vector("TABLET (CHEWABLE)")), drug).isEmpty,
        check(canadian.copy(routes = Vector("BUCCAL")), drug).isEmpty,
        check(canadian, drug.copy(amount = "0.5", unit = "G")).isDefined,
        check(canadian, drug.copy(unit = "MCG")).isEmpty,
        check(canadian, drug.copy(name = "EXAMPLE HYDROCHLORIDE")).isEmpty,
        check(canadian, drug.copy(denominator = "5", denominatorUnit = "ML")).isEmpty,
        check(canadian, drug.copy(base = "Y")).isEmpty)
    },
    test("generic clinical product admits different brand names but no additional active ingredient") {
      val signature = profile(generic, snapshot).get
      val other = canadian.copy(brandName = "DIFFERENT BRAND")
      assertTrue(candidate(signature, aliases, other, Vector(drug)).isDefined,
        candidate(signature, aliases, other, Vector(drug, drug.copy(name = "OTHER"))).isEmpty)
    },
    test("combination requires a one-to-one match for every component and strength") {
      val second = RxConcept("22", "IN", "Second")
      val combined = snapshot.copy(
        concepts = snapshot.concepts ++ Vector(second, RxConcept("23", "SCDC", "Second 10 MG")),
        relations = snapshot.relations ++ Vector(edge("10", "23", "consists_of"), edge("23", "22", "has_ingredient")),
        attributes = snapshot.attributes :+ RxAttribute("23", "2", "RXN_STRENGTH", "10 MG", "A2"))
      val signature = profile(generic, combined).get
      val ingredientNames = aliases.updated("22", Set("second"))
      val extra = drug.copy(name = "SECOND", amount = "10")
      def matched(rows: Ingredient*) = candidate(signature, ingredientNames, canadian, rows.toVector)
      assertTrue(matched(extra, drug).isDefined, matched(drug).isEmpty, matched(drug, extra.copy(amount = "100")).isEmpty,
        matched(drug, drug).isEmpty, matched(drug, extra.copy(name = "UNRELATED")).isEmpty)
    },
    test("missing brand, conflicting strength evidence, salt and unmapped release mechanisms stay unresolved") {
      val noBrand = snapshot.copy(relations = snapshot.relations.filterNot(r => r.target == brand.rxcui))
      val salt = snapshot.copy(concepts = snapshot.concepts :+ RxConcept("50", "PIN", "Example salt"),
        relations = snapshot.relations :+ edge("21", "50", "has_precise_ingredient"))
      val conflict = snapshot.copy(attributes = snapshot.attributes :+ RxAttribute("21", "1", "RXN_STRENGTH", "600 MG", "A2"))
      val er = snapshot.copy(concepts = snapshot.concepts.filterNot(_ == form) :+ form.copy(display = "Extended Release Oral Tablet"))
      assertTrue(profile(branded, noBrand).isEmpty, profile(branded, salt).isEmpty,
        profile(generic, conflict).isEmpty, profile(generic, er).isEmpty)
    },
    test("an explicitly route-qualified nonoral form must agree with both Canadian fields") {
      val rectal = snapshot.copy(concepts = snapshot.concepts.filterNot(_ == form) :+ form.copy(display = "Rectal Suppository"))
      val signature = profile(generic, rectal).get
      val suppository = canadian.copy(forms = Vector("SUPPOSITORY"), routes = Vector("RECTAL"))
      assertTrue(candidate(signature, aliases, suppository, Vector(drug)).isDefined,
        candidate(signature, aliases, suppository.copy(routes = Vector("VAGINAL")), Vector(drug)).isEmpty)
    },
    test("enteric-coated matches delayed-release oral tablet but excludes ordinary and chewable tablets") {
      val delayed = snapshot.copy(concepts = snapshot.concepts.filterNot(_ == form) :+ form.copy(display = "Delayed Release Oral Tablet"))
      val signature = profile(generic, delayed).get
      assertTrue(candidate(signature, aliases, canadian.copy(forms = Vector("TABLET (ENTERIC-COATED)")), Vector(drug)).isDefined,
        candidate(signature, aliases, canadian, Vector(drug)).isEmpty,
        candidate(signature, aliases, canadian.copy(forms = Vector("TABLET (CHEWABLE)")), Vector(drug)).isEmpty)
    }
  )
