package lab

final case class ProductSelection(
  status: String, selected: Option[ConceptRef], candidates: Vector[Candidate],
  evidence: Option[ProductMatchEvidence], diagnostics: Vector[String]
)

/** Conservative single-component product matching over imported RxNorm evidence. */
object ProductSelector:
  def select(m: Mention, initial: ConceptRef, s: RxSnapshot): ProductSelection =
    def stop(code: String, message: String, choices: Vector[Candidate] = Vector.empty,
        status: String = "needsClarification"): ProductSelection =
      ProductSelection(status,None,choices,None,Vector(s"$code: $message"))
    if m.productStrength.isEmpty || m.doseForm.isEmpty then
      return stop("PRODUCT_FIELDS_REQUIRED","productStrength and doseForm must both be explicit")
    if m.role == "activeIngredient" then
      return stop("PRODUCT_ROLE_MISMATCH","activeIngredient cannot request a pharmaceutical product",status="invalidRole")
    if !Set("IN","BN","SCD","SBD")(initial.tty) then
      return stop("PRODUCT_MATCH_SCOPE_UNSUPPORTED","this policy supports single-component products with a direct IN ingredient")
    if !s.sha256.contains("RXNSAT.RRF") then
      return stop("PRODUCT_INDEX_REQUIRED","import matching RXNSAT.RRF attributes for this release first")
    val strength = ProductStrength.parse(m.productStrength.get).get
    val forms = Resolver.candidates(m.doseForm.get,s).filter(_.concept.tty == "DF")
    if forms.isEmpty then return stop("DOSE_FORM_UNKNOWN","no exact imported dose-form name",status="productNotFound")
    if forms.size > 1 then return stop("DOSE_FORM_AMBIGUOUS","dose form requires explicit selection",forms)
    val form = forms.head.concept
    val concepts = s.concepts.map(c => c.rxcui -> c).toMap
    def ref(c: RxConcept): ConceptRef = ConceptRef(initial.system,c.rxcui,s.release,c.display,c.tty)
    val outgoing = s.relations.groupBy(_.source).view.mapValues(_.sortBy(r => (r.rela,r.target,r.rui))).toMap
    def edges(id: String, relation: String): Vector[RxRelation] =
      outgoing.getOrElse(id,Vector.empty).filter(_.rela == relation).groupBy(_.target).toVector.sortBy(_._1).map(_._2.head)
    def evidence(r: RxRelation): RelationshipEvidence = RelationshipEvidence(r.source,r.target,r.rela,r.rui)
    val potential = s.concepts.filter { p =>
      initial.tty match
        case "IN" => p.tty == "SCD" && edges(p.rxcui,"consists_of").exists(r =>
          edges(r.target,"has_ingredient").exists(_.target == initial.rxcui))
        case "BN" => p.tty == "SBD" && edges(p.rxcui,"has_ingredient").exists(_.target == initial.rxcui)
        case _ => p.rxcui == initial.rxcui
    }.filter(p => edges(p.rxcui,"has_dose_form").exists(_.target == form.rxcui)).sortBy(_.rxcui)
    var incomplete = false
    val matches = potential.flatMap { product =>
      val genericEdges = if product.tty == "SBD" then
        edges(product.rxcui,"tradename_of").filter(r => concepts.get(r.target).exists(_.tty == "SCD"))
      else Vector.empty
      val generic = if product.tty == "SCD" then Some(product) else
        Option.when(genericEdges.size == 1)(concepts(genericEdges.head.target))
      if generic.isEmpty then incomplete = true
      generic.toVector.flatMap { g =>
        val components = edges(g.rxcui,"consists_of").filter(r => concepts.get(r.target).exists(_.tty == "SCDC"))
        // A single ingredient/strength input must never silently select a combination.
        if components.isEmpty then
          incomplete = true
          Vector.empty
        else if components.size != 1 then Vector.empty
        else
          val componentEdge = components.head
          val ingredientEdges = edges(componentEdge.target,"has_ingredient").filter(r => concepts.get(r.target).exists(_.tty == "IN"))
          val precise = edges(componentEdge.target,"has_precise_ingredient")
          val compatible = ingredientEdges.size == 1 && precise.isEmpty &&
            (initial.tty != "IN" || ingredientEdges.head.target == initial.rxcui)
          if !compatible then
            if initial.tty != "IN" then incomplete = true
            Vector.empty
          else
            val attrs = s.attributes.filter(a => a.rxcui == componentEdge.target && a.atn == "RXN_STRENGTH").sortBy(a => (a.rxaui,a.atui,a.value))
            val parsed = attrs.map(a => a -> ProductStrength.parse(a.value))
            if parsed.isEmpty || parsed.exists(_._2.isEmpty) ||
                parsed.exists(x => !x._2.get.equivalent(parsed.head._2.get)) then
              incomplete = true
              Vector.empty
            else if !strength.equivalent(parsed.head._2.get) then Vector.empty
            else
              val attr = attrs.head
              val formEdge = edges(product.rxcui,"has_dose_form").find(_.target == form.rxcui).get
              val brandEdges = if initial.tty == "BN" then edges(product.rxcui,"has_ingredient").filter(_.target == initial.rxcui) else Vector.empty
              Vector(ProductMatchEvidence(ProductAttributes.policy,ref(product),form,ref(concepts(componentEdge.target)),
                AttributeEvidence(attr.rxcui,attr.rxaui,attr.atn,attr.value,attr.atui),
                (brandEdges ++ genericEdges ++ Vector(componentEdge,ingredientEdges.head,formEdge)).map(evidence)))
      }
    }
    val choices = matches.map(x => Candidate(x.product,Vector.empty))
    if incomplete then stop("PRODUCT_EVIDENCE_INCOMPLETE","a potential single-component product has missing or conflicting strength evidence",choices)
    else if matches.isEmpty then stop("PRODUCT_NOT_FOUND","no supported single-component product matches the explicit strength and dose form",status="productNotFound")
    else if matches.size > 1 then stop("PRODUCT_AMBIGUOUS","multiple products match; no product was selected",choices)
    else ProductSelection("resolved",Some(matches.head.product),choices,Some(matches.head),Vector.empty)
