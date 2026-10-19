package lab

import zio.test.*

object ProductSpec extends ZIOSpecDefault:
  private val source = "medication paracetamol { 1 mg strength \"500 mg\" doseForm \"Oral Tablet\" route PO frequency PRN }"
  private val mention = Mention("m1","paracetamol","medication",
    SourceLocation("file:///product.clinical",Position(0,0,0),Position(0,source.length,source.length),source),
    Dose(BigDecimal(1),"mg"),"PO","PRN","P1","O1",Some("500 mg"),Some("Oral Tablet"))
  private val request = AstRequest("1","exact-v1","2026-10-05",DocumentSource(mention.source.uri,source),Vector(mention))
  private val concepts = Vector(RxConcept("161","IN","acetaminophen"),RxConcept("10","SCD","synthetic product"),
    RxConcept("20","SCDC","synthetic component"),RxConcept("30","DF","Oral Tablet"))
  private val snapshot = RxSnapshot(request.terminologyRelease,Rrf.scope,Map("RXNSAT.RRF" -> "synthetic"),concepts,
    Vector(RxDescription("161","1","paracetamol","paracetamol","SY","TEST"),
      RxDescription("30","4","Oral Tablet","oral tablet","DF","RXNORM")),
    Vector(RxRelation("10","20","consists_of","R1"),RxRelation("20","161","has_ingredient","R2"),
      RxRelation("10","30","has_dose_form","R3")),Vector(RxAttribute("20","2","RXN_STRENGTH","500 MG","AT1")))
  private def result(s: RxSnapshot = snapshot, m: Mention = mention): Resolution =
    Resolver.resolve(request.copy(mentions=Vector(m)),s).resolutions.head

  def spec = suite("Explicit product matching")(
    test("selects a product from imported ingredient, component strength and dose form") {
      val r = result()
      assertTrue(r.status == "resolved",r.initialConcept.exists(_.rxcui == "161"),r.selectedProduct.exists(_.rxcui == "10"),
        r.productEvidence.exists(_.strength.atui == "AT1"),r.ingredients.map(_.concept.rxcui) == Vector("161"),
        !r.diagnostics.exists(_.startsWith("PRODUCT_NOT_SELECTED")))
    },
    test("administered dose is not used as a product-strength filter") {
      assertTrue(result(m=mention.copy(dose=Dose(BigDecimal(10),"mg"))).selectedProduct.exists(_.rxcui == "10"))
    },
    test("compares mass units and ratios exactly without binary floating point") {
      assertTrue(ProductStrength.parse("0.5 g").get.equivalent(ProductStrength.parse("500 mg").get),
        ProductStrength.parse("500000 mcg").get.equivalent(ProductStrength.parse("500 mg").get),
        ProductStrength.parse("160 mg/5 ml").get.equivalent(ProductStrength.parse("32 MG/ML").get),
        !ProductStrength.parse("32 mg").get.equivalent(ProductStrength.parse("32 mg/ml").get),
        ProductStrength.parse("0 mg").isEmpty,ProductStrength.parse("3 mg/0 ml").isEmpty)
    },
    test("accepts equivalent explicit strength representations") {
      assertTrue(result(m=mention.copy(productStrength=Some("0.5 g"))).status == "resolved")
    },
    test("known ingredient with wrong strength is a product failure, not an unknown medication") {
      val r = result(m=mention.copy(productStrength=Some("499 mg")))
      assertTrue(r.status == "productNotFound",r.initialConcept.exists(_.rxcui == "161"),r.selectedProduct.isEmpty)
    },
    test("a different or unknown dose form cannot match") {
      val r = result(m=mention.copy(doseForm=Some("Unknown Form")))
      assertTrue(r.status == "productNotFound",r.diagnostics.exists(_.startsWith("DOSE_FORM_UNKNOWN")))
    },
    test("multiple matching products require clarification") {
      val s = snapshot.copy(concepts=snapshot.concepts :+ RxConcept("11","SCD","other synthetic product"),
        relations=snapshot.relations ++ Vector(RxRelation("11","20","consists_of","R4"),RxRelation("11","30","has_dose_form","R5")))
      assertTrue(result(s).status == "needsClarification",result(s).selectedProduct.isEmpty,result(s).candidates.size == 2)
    },
    test("combination products are not selected using a single strength") {
      val s = snapshot.copy(concepts=snapshot.concepts ++ Vector(RxConcept("21","SCDC","other component"),RxConcept("162","IN","other ingredient")),
        relations=snapshot.relations ++ Vector(RxRelation("10","21","consists_of","R4"),RxRelation("21","162","has_ingredient","R5")))
      assertTrue(result(s).selectedProduct.isEmpty,result(s).status == "productNotFound")
    },
    test("missing or conflicting component strength cannot be accepted") {
      val missing = snapshot.copy(attributes=Vector.empty)
      val conflict = snapshot.copy(attributes=snapshot.attributes :+ RxAttribute("20","2","RXN_STRENGTH","250 MG","AT2"))
      assertTrue(result(missing).status == "needsClarification",result(conflict).status == "needsClarification")
    },
    test("brand selection retains the generic product path and the IN ingredient") {
      val s = snapshot.copy(concepts=snapshot.concepts ++ Vector(RxConcept("40","BN","TestBrand"),RxConcept("41","SBD","synthetic brand product")),
        descriptions=snapshot.descriptions :+ RxDescription("40","5","TestBrand","testbrand","BN","RXNORM"),
        relations=snapshot.relations ++ Vector(RxRelation("41","40","has_ingredient","R4"),RxRelation("41","10","tradename_of","R5"),
          RxRelation("41","30","has_dose_form","R6")))
      val text = source.replace("paracetamol","TestBrand")
      val m = mention.copy(originalText="TestBrand",source=mention.source.copy(text=text,end=Position(0,text.length,text.length)))
      val r = Resolver.resolve(request.copy(document=request.document.copy(text=text),mentions=Vector(m)),s).resolutions.head
      assertTrue(r.status == "resolved",r.selectedProduct.exists(_.rxcui == "41"),r.ingredients.map(_.concept.rxcui) == Vector("161"))
    },
    test("absence of RXNSAT metadata never counts as a verified product match") {
      assertTrue(result(snapshot.copy(sha256=Map.empty)).status == "needsClarification")
    },
    test("an activeIngredient semantic role cannot be promoted to a product") {
      assertTrue(result(m=mention.copy(role="activeIngredient")).status == "invalidRole")
    }
  )
