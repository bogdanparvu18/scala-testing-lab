package lab

/** Pure, deterministic policy. No I/O, product guessing, or clinical dose-safety claims. */
object Resolver:
  private val ingredients = Set("IN", "PIN")
  private val products = Set("SCD", "SBD")
  private val medicationTypes = Set("IN", "PIN", "MIN", "BN", "SCD", "SBD")

  private def reference(c: RxConcept, s: RxSnapshot): ConceptRef =
    ConceptRef("http://www.nlm.nih.gov/research/umls/rxnorm", c.rxcui, s.release, c.display, c.tty)

  /** All exact lexical candidates are retained, including conflicting source synonyms. */
  def candidates(name: String, s: RxSnapshot): Vector[Candidate] =
    require(name.trim.nonEmpty, "Empty lookup name")
    val concepts = s.concepts.map(c => c.rxcui -> c).toMap
    s.descriptions.filter(d => TextKey.normalize(d.text) == TextKey.normalize(name))
      .groupBy(_.rxcui).toVector.sortBy(_._1).map { (id, ds) =>
        val c = concepts.getOrElse(id, throw IllegalStateException(s"Description refers to missing concept $id"))
        Candidate(reference(c,s), ds.sortBy(_.rxaui).map(d => MatchEvidence(d.rxaui,d.text,d.tty,d.sab)))
      }

  def resolve(a: AstRequest, s: RxSnapshot): ResolutionReport =
    InputValidation.validate(a)
    require(a.terminologyRelease == s.release, "Terminology release mismatch")
    require(s.scope == Rrf.scope, "Unsupported terminology index policy")
    val concepts = s.concepts.map(c => c.rxcui -> c).toMap
    val edges = s.relations.groupBy(_.source).view.mapValues(_.sortBy(r => (r.rela,r.target,r.rui))).toMap
    def ref(c: RxConcept) = reference(c,s)
    def allowedStep(from: RxConcept, r: RxRelation, to: RxConcept): Boolean =
      (from.tty, r.rela, to.tty) match
        case ("SBD", "tradename_of", "SCD") => true
        case ("SBD" | "SCD", "consists_of", "SCDC") => true
        case ("SBD", "consists_of", "SBDC") => true
        case ("SBDC", "tradename_of", "SCDC") => true
        case ("SCDC", "has_ingredient", "IN") => true
        case ("SCDC", "has_precise_ingredient", "PIN") => true
        case ("SCD", "has_ingredients", "MIN") => true
        case ("MIN", "has_part", "IN" | "PIN") => true
        case ("PIN", "form_of", "IN") => true
        case _ => false
    def derive(start: RxConcept): Vector[IngredientEvidence] =
      def visit(c: RxConcept, path: Vector[RelationshipEvidence], seen: Set[String]): Vector[IngredientEvidence] =
        val here = if ingredients(c.tty) then Vector(IngredientEvidence(ref(c), path)) else Vector.empty
        here ++ edges.getOrElse(c.rxcui, Vector.empty).flatMap { r =>
          concepts.get(r.target).filter(t => !seen(t.rxcui) && allowedStep(c,r,t)).toVector.flatMap { t =>
            visit(t, path :+ RelationshipEvidence(r.source,r.target,r.rela,r.rui), seen + t.rxcui)
          }
        }
      // A brand is not a selected product. Do not derive a product's ingredient set from brand alone.
      if start.tty == "BN" then Vector.empty
      else visit(start, Vector.empty, Set(start.rxcui)).groupBy(_.concept.rxcui).toVector.sortBy(_._1)
        .map { (_, paths) => paths.minBy(p => (p.path.size, p.path.map(_.rui).mkString("|"))) }
    val results = a.mentions.sortBy(_.id).map { m =>
      val found = candidates(m.originalText,s)
      val allowed = found.filter { c => m.role match
        case "activeIngredient" => ingredients(c.concept.tty)
        case "medicationProduct" => products(c.concept.tty)
        case _ => medicationTypes(c.concept.tty)
      }
      val unsupported = m.productStrength.nonEmpty || m.doseForm.nonEmpty
      if unsupported then Resolution(m,"needsClarification",None,None,Vector.empty,found,"none",
        Vector("STRUCTURED_PRODUCT_FILTERS_NOT_IMPLEMENTED: supplied product qualifiers were not used; no binding accepted"))
      else if found.isEmpty then Resolution(m,"unresolved",None,None,Vector.empty,Vector.empty,"none",
        Vector("UNRESOLVED_IN_DATASET: no exact imported name in this local release; this does not mean the medication does not exist"))
      else if allowed.isEmpty then Resolution(m,"invalidRole",None,None,Vector.empty,found,"none",
        Vector("SEMANTIC_TYPE_MISMATCH: name exists but cannot fill this AST role"))
      else if allowed.size > 1 then Resolution(m,"needsClarification",None,None,Vector.empty,allowed,"none",
        Vector("AMBIGUOUS_EXACT_MATCH: explicit selection required"))
      else
        val c = allowed.head.concept
        val product = if products(c.tty) then Some(c) else None
        val derived = derive(concepts(c.rxcui))
        val diagnostics =
          (if product.isEmpty then Vector("PRODUCT_NOT_SELECTED: administered dose is not product strength") else Vector.empty) ++
          (if products(c.tty) && derived.isEmpty then Vector("INGREDIENT_EVIDENCE_MISSING") else Vector.empty)
        Resolution(m,"resolved",Some(c),product,derived,allowed,"exact_imported_name",diagnostics)
    }
    val shared = results.filter(_.status == "resolved").flatMap { r =>
      r.ingredients.map(i => (r.mention.patientRef, i.concept.rxcui) -> (r.mention.orderId,i.concept))
    }.groupBy(_._1).toVector.sortBy(_._1).flatMap { (key, values) =>
      val orders = values.map(_._2._1).distinct.sorted
      if orders.size > 1 then Some(SharedIngredient(key._1,orders,values.head._2._2,
        "Shared ingredient in these input orders; review context. This is not a dose-safety or interaction assessment.")) else None
    }
    import zio.json.*
    ResolutionReport("2",a.policyVersion,s.release,Hashing.fingerprint(s),s.scope,Hashing.sha256(a.toJson),results,shared)
