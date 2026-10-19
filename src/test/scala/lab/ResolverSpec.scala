package lab

import zio.test.*
import zio.json.*

object ResolverSpec extends ZIOSpecDefault:
  private val source = "medication paracetamol { 1 mg route PO frequency PRN }"
  private val mention = Mention("m1","paracetamol","medication",
    SourceLocation("file:///demo.clinical",Position(0,0,0),Position(0,source.length,source.length),source),
    Dose(BigDecimal(1),"mg"),"PO","PRN","P1","O1")
  private val request = AstRequest("1","exact-v1","2026-10-05",DocumentSource(mention.source.uri,source),Vector(mention))
  private val snapshot = RxSnapshot("2026-10-05",Rrf.scope,Map("RXNCONSO.RRF" -> "synthetic"),
    Vector(RxConcept("161","IN","acetaminophen")),
    Vector(RxDescription("161","test-A1","paracetamol","paracetamol","SY","MSH")),Vector.empty,Vector.empty)
  def spec = suite("Resolution policy")(
    test("ingredient binding never promotes administered dose into a product") {
      val r = Resolver.resolve(request,snapshot).resolutions.head
      assertTrue(r.status == "resolved",r.initialConcept.exists(_.rxcui == "161"),r.selectedProduct.isEmpty,
        r.ingredients.map(_.concept.rxcui) == Vector("161"),r.matchMethod == "exact_imported_name")
    },
    test("unknown spelling remains unresolved") {
      val m = mention.copy(originalText="paracetamo")
      assertTrue(Resolver.resolve(request.copy(mentions=Vector(m)),snapshot).resolutions.head.status == "unresolved")
    },
    test("ambiguous exact names require selection") {
      val s = snapshot.copy(concepts=snapshot.concepts :+ RxConcept("999","BN","synthetic brand"),
        descriptions=snapshot.descriptions :+ RxDescription("999","test-A2","paracetamol","paracetamol","SY","MSH"))
      val r = Resolver.resolve(request,s).resolutions.head
      assertTrue(r.status == "needsClarification",r.initialConcept.isEmpty,r.candidates.size == 2)
    },
    test("ingredient is not allowed in medicationProduct role") {
      val r = Resolver.resolve(request.copy(mentions=Vector(mention.copy(role="medicationProduct"))),snapshot).resolutions.head
      assertTrue(r.status == "invalidRole",r.initialConcept.isEmpty)
    },
    test("partial product filters cannot be silently ignored") {
      val r = Resolver.resolve(request.copy(mentions=Vector(mention.copy(productStrength=Some("500 mg")))),snapshot).resolutions.head
      assertTrue(r.status == "needsClarification",r.selectedProduct.isEmpty,r.diagnostics.exists(_.startsWith("PRODUCT_FIELDS_REQUIRED")))
    },
    test("brand stays brand and does not claim a complete ingredient set") {
      val s = snapshot.copy(concepts=Vector(RxConcept("999","BN","synthetic brand")),
        descriptions=Vector(RxDescription("999","A2","paracetamol","paracetamol","SY","MSH")))
      val r = Resolver.resolve(request,s).resolutions.head
      assertTrue(r.initialConcept.exists(_.tty == "BN"),r.selectedProduct.isEmpty,r.ingredients.isEmpty)
    },
    test("typed component paths preserve every combination ingredient and provenance") {
      val s = snapshot.copy(concepts=snapshot.concepts ++ Vector(RxConcept("prod","SCD","synthetic combination"),
        RxConcept("comp1","SCDC","component one"),RxConcept("comp2","SCDC","component two"),RxConcept("other","IN","other ingredient")),
        descriptions=Vector(RxDescription("prod","A3","paracetamol","paracetamol","SY","MSH")),
        relations=Vector(RxRelation("prod","comp1","consists_of","R1"),RxRelation("prod","comp2","consists_of","R2"),
          RxRelation("comp1","161","has_ingredient","R3"),RxRelation("comp2","other","has_ingredient","R4")))
      val r = Resolver.resolve(request,s).resolutions.head
      assertTrue(r.ingredients.map(_.concept.rxcui) == Vector("161","other"),r.ingredients.forall(_.path.size == 2))
    },
    test("shared ingredient rule groups by patient and distinct order") {
      val a = request.copy(mentions=Vector(mention,mention.copy(id="m2",orderId="O2"),mention.copy(id="m3",orderId="O3",patientRef="P2")))
      val r = Resolver.resolve(a,snapshot)
      assertTrue(r.sharedIngredients.size == 1,r.sharedIngredients.head.orderIds == Vector("O1","O2"))
    },
    test("same input snapshot policy produces byte-identical result") {
      assertTrue(Resolver.resolve(request,snapshot).toJson == Resolver.resolve(request,snapshot).toJson)
    },
    test("decoder rejects unknown keys instead of ignoring semantic qualifiers") {
      val json = request.toJson.dropRight(1) + ",\"unexpectedConstraint\":true}"
      assertTrue(json.fromJson[AstRequest].isLeft)
    },
    test("source synonym resolves without a local alias and retains its source evidence") {
      val r = Resolver.resolve(request,snapshot).resolutions.head
      assertTrue(r.status == "resolved", r.initialConcept.exists(_.rxcui == "161"),
        r.candidates.head.names.head.sab == "MSH", r.candidates.head.names.head.tty == "SY")
    },
    test("canonical name alone does not invent missing synonyms") {
      val s = snapshot.copy(descriptions=Vector(RxDescription("161","A0","acetaminophen","acetaminophen","IN","RXNORM")))
      assertTrue(Resolver.resolve(request,s).resolutions.head.status == "unresolved")
    },
    test("foreign-source-only type cannot become an ingredient by its spelling") {
      val s = snapshot.copy(concepts=Vector(RxConcept("161","DF","synthetic dose form")))
      val r = Resolver.resolve(request,s).resolutions.head
      assertTrue(r.status == "invalidRole",r.initialConcept.isEmpty)
    },
    test("index scope cannot be silently mixed with legacy seed subset") {
      assertTrue(scala.util.Try(Resolver.resolve(request,snapshot.copy(scope="legacy-seed"))).isFailure)
    },
    test("source evidence and release mismatches fail closed") {
      assertTrue(scala.util.Try(Resolver.resolve(request.copy(terminologyRelease="other"),snapshot)).isFailure,
        scala.util.Try(Resolver.resolve(request.copy(document=request.document.copy(text="changed")),snapshot)).isFailure)
    }
  )
