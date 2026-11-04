package lab

import zio.json.*
import zio.test.*

/** Synthetic identifiers and products exercise identity persistence, not prescribing. */
object ProductBindingSpec extends ZIOSpecDefault:
  private val release = "2026-10-05"
  private val source = "medication myMedicine: rxcui \"10\" rxnormRelease \"2026-10-05\" dose 1mg route PO frequency PRN"
  private val mention = Mention("m1","myMedicine","medication",
    SourceLocation("file:///binding.clinical",Position(0,0,0),Position(0,source.length,source.length),source),
    Dose(BigDecimal(1),"mg"),"PO","PRN","P1","O1",productBinding=Some(ProductBinding("10",release)))
  private val request = AstRequest("2","explicit-product-v1",release,DocumentSource(mention.source.uri,source),Vector(mention))
  private val snapshot = RxSnapshot(release,Rrf.scope,Map("RXNSAT.RRF" -> "synthetic"),
    Vector(RxConcept("161","IN","ingredient one"),RxConcept("162","IN","ingredient two"),
      RxConcept("10","SCD","synthetic product 500 mg"),RxConcept("11","SCD","synthetic product 250 mg"),
      RxConcept("20","SCDC","component 500 mg"),RxConcept("21","SCDC","component 250 mg"),
      RxConcept("30","DF","Oral Tablet"),RxConcept("41","SBD","synthetic branded product")),
    // The local alias happens to be a lexical match for a DIFFERENT product.
    Vector(RxDescription("11","A11","myMedicine","mymedicine","SY","TEST"),
      RxDescription("30","A30","Oral Tablet","oral tablet","DF","RXNORM")),
    Vector(RxRelation("10","20","consists_of","R1"),RxRelation("20","161","has_ingredient","R2"),
      RxRelation("10","30","has_dose_form","R3"),RxRelation("11","21","consists_of","R4"),
      RxRelation("21","162","has_ingredient","R5"),RxRelation("11","30","has_dose_form","R6"),
      RxRelation("41","10","tradename_of","R7"),RxRelation("41","30","has_dose_form","R8")),
    Vector(RxAttribute("20","A20","RXN_STRENGTH","500 MG","AT1"),RxAttribute("21","A21","RXN_STRENGTH","250 MG","AT2")))
  private def result(m: Mention = mention, s: RxSnapshot = snapshot): Resolution =
    Resolver.resolve(request.copy(mentions=Vector(m)),s).resolutions.head

  def spec = suite("Persistent explicit RxCUI binding")(
    test("binding wins over the local alias and preserves provenance") {
      val r = result()
      assertTrue(r.status == "resolved",r.selectedProduct.exists(_.rxcui == "10"),
        r.selectedProduct.exists(_.release == release),r.mention.originalText == "myMedicine",
        r.matchMethod == "explicit_rxcui",r.ingredients.map(_.concept.rxcui) == Vector("161"),
        r.ingredients.head.path.map(_.rui) == Vector("R1","R2"),!r.clinicianConfirmed)
    },
    test("unmatched aliases can still identify a bound product") {
      val text = source.replace("myMedicine","LocalAlias")
      val m = mention.copy(originalText="LocalAlias",source=mention.source.copy(text=text,end=Position(0,text.length,text.length)))
      val r = Resolver.resolve(request.copy(document=request.document.copy(text=text),mentions=Vector(m)),snapshot).resolutions.head
      assertTrue(r.status == "resolved",r.selectedProduct.exists(_.rxcui == "10"))
    },
    test("save/load JSON round trip retains identifier, release and alias") {
      val decoded = request.toJson.fromJson[AstRequest].toOption.get
      assertTrue(decoded == request,Resolver.resolve(decoded,snapshot).toJson == Resolver.resolve(request,snapshot).toJson)
    },
    test("missing explicit ID never falls back to the alias match") {
      val r = result(mention.copy(productBinding=Some(ProductBinding("999",release))))
      assertTrue(r.status == "productNotFound",r.selectedProduct.isEmpty,r.initialConcept.isEmpty,
        r.diagnostics.exists(_.startsWith("PRODUCT_RXCUI_NOT_FOUND")))
    },
    test("binding release mismatch never reinterprets the identifier") {
      val r = result(mention.copy(productBinding=Some(ProductBinding("10","2026-09-07"))))
      assertTrue(r.status == "needsClarification",r.selectedProduct.isEmpty,
        r.diagnostics.exists(_.startsWith("PRODUCT_RELEASE_MISMATCH")))
    },
    test("ingredient IDs and activeIngredient roles cannot be bound as products") {
      val wrongId = result(mention.copy(productBinding=Some(ProductBinding("161",release))))
      val wrongRole = result(mention.copy(role="activeIngredient"))
      assertTrue(wrongId.status == "invalidRole",wrongId.selectedProduct.isEmpty,
        wrongRole.status == "invalidRole",wrongRole.selectedProduct.isEmpty)
    },
    test("bound products do not require optional strength import") {
      val r = result(s=snapshot.copy(sha256=Map("RXNCONSO.RRF" -> "synthetic"),attributes=Vector.empty))
      assertTrue(r.status == "resolved",r.selectedProduct.exists(_.rxcui == "10"),r.productEvidence.isEmpty)
    },
    test("explicit strength and form are verified against the selected product") {
      val r = result(mention.copy(productStrength=Some("0.5 g"),doseForm=Some("Oral Tablet")))
      assertTrue(r.status == "resolved",r.selectedProduct.exists(_.rxcui == "10"),
        r.productEvidence.exists(_.product.rxcui == "10"),r.productEvidence.exists(_.strength.atui == "AT1"))
    },
    test("conflicting strength cannot switch to another matching product") {
      val r = result(mention.copy(productStrength=Some("250 mg"),doseForm=Some("Oral Tablet")))
      assertTrue(r.status == "productNotFound",r.selectedProduct.isEmpty,r.initialConcept.exists(_.rxcui == "10"))
    },
    test("partial qualifiers and absent qualifier evidence fail closed") {
      val partial = result(mention.copy(productStrength=Some("500 mg")))
      val missing = result(mention.copy(productStrength=Some("500 mg"),doseForm=Some("Oral Tablet")),snapshot.copy(attributes=Vector.empty))
      assertTrue(partial.status == "needsClarification",partial.selectedProduct.isEmpty,
        missing.status == "needsClarification",missing.selectedProduct.isEmpty)
    },
    test("administered amount changes do not alter the selected product") {
      val r = result(mention.copy(dose=Dose(BigDecimal(20),"mg")))
      assertTrue(r.selectedProduct.exists(_.rxcui == "10"),r.mention.dose.amount == 20)
    },
    test("branded product keeps its own ID and derives generic ingredient evidence") {
      val r = result(mention.copy(productBinding=Some(ProductBinding("41",release))))
      assertTrue(r.status == "resolved",r.selectedProduct.exists(_.rxcui == "41"),
        r.ingredients.map(_.concept.rxcui) == Vector("161"),r.ingredients.head.path.map(_.rui) == Vector("R7","R1","R2"))
    },
    test("explicit combination selection retains every component ingredient") {
      val s = snapshot.copy(relations=snapshot.relations :+ RxRelation("10","21","consists_of","R9"))
      val r = result(s=s)
      assertTrue(r.status == "resolved",r.selectedProduct.exists(_.rxcui == "10"),
        r.ingredients.map(_.concept.rxcui) == Vector("161","162"))
    },
    test("mixed schema2 documents retain exact-name behavior for unbound mentions") {
      val bound = mention
      val unbound = mention.copy(id="m2",orderId="O2",productBinding=None)
      val r = Resolver.resolve(request.copy(mentions=Vector(bound,unbound)),snapshot).resolutions
      assertTrue(r.head.selectedProduct.exists(_.rxcui == "10"),r.last.selectedProduct.exists(_.rxcui == "11"),
        r.last.matchMethod == "exact_imported_name")
    },
    test("legacy schema cannot silently acquire explicit binding semantics") {
      assertTrue(scala.util.Try(InputValidation.validate(request.copy(schemaVersion="1",policyVersion="exact-v1"))).isFailure,
        scala.util.Try(InputValidation.validate(request.copy(policyVersion="exact-v1"))).isFailure,
        scala.util.Try(InputValidation.validate(request.copy(schemaVersion="3"))).isFailure)
    },
    test("malformed IDs and release dates are rejected before resolution") {
      val badIds = Vector("", "0", "-10", "10.0", "abc", " 10", "01")
      val badDates = Vector("", "0000-01-01", "2026-2-5", "2026-02-30", "2026-13-01", "not-a-release")
      assertTrue(badIds.forall(id => scala.util.Try(result(mention.copy(productBinding=Some(ProductBinding(id,release))))).isFailure),
        badDates.forall(date => scala.util.Try(result(mention.copy(productBinding=Some(ProductBinding("10",date))))).isFailure))
    },
    test("unknown binding qualifiers are rejected by the JSON decoder") {
      assertTrue("""{"rxcui":"10","release":"2026-10-05","replacement":"11"}""".fromJson[ProductBinding].isLeft)
    }
  )
