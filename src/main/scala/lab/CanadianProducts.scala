package lab

import zio.json.*

final case class CanadianProduct(
  din: String, drugCode: Int, brandName: String, ingredients: Vector[String], forms: Vector[String], routes: Vector[String]
) derives JsonCodec

final case class CanadianProductCandidates(
  release: String, rxcui: String, rxnormDisplay: String, items: Vector[CanadianProduct]
) derives JsonCodec

/** A candidate for clinician confirmation, never a cross-terminology equivalence assertion.
  * Mapped forms have an explicit route. Release durations, delivery devices, salt/base
  * conversions and dosage forms without a supported correspondence are left unresolved.
  */
private[lab] object CanadianProducts:
  private val oralForms = Map(
    "oral tablet" -> Set("TABLET", "TABLET (IMMEDIATE-RELEASE)"),
    "oral capsule" -> Set("CAPSULE", "CAPSULE (IMMEDIATE-RELEASE)"),
    "chewable tablet" -> Set("TABLET (CHEWABLE)"),
    "delayed release oral tablet" -> Set("TABLET (DELAYED-RELEASE)", "TABLET (ENTERIC-COATED)"),
    "delayed release oral capsule" -> Set("CAPSULE (DELAYED-RELEASE)", "CAPSULE (ENTERIC-COATED)"),
    "disintegrating oral tablet" -> Set("TABLET (ORALLY-DISINTEGRATING)"),
    "effervescent oral tablet" -> Set("TABLET (EFFERVESCENT)"),
    "powder for oral solution" -> Set("POWDER FOR SOLUTION"),
    "powder for oral suspension" -> Set("POWDER FOR SUSPENSION"),
    "tablet for oral suspension" -> Set("TABLET FOR SUSPENSION")
  )

  // For explicitly route-qualified names, keep the rest of the form intact. A
  // plain solution and a suspension, or a spray and a metered spray, stay distinct.
  private val routes = Set("oral", "buccal", "sublingual", "rectal", "vaginal", "nasal", "ophthalmic", "otic",
    "topical", "inhalation", "intravesical", "intraperitoneal", "intratracheal", "urethral")
  private def administration(form: String): Option[(String, Set[String])] =
    val name = TextKey.normalize(form)
    oralForms.get(name).map(forms => ("ORAL", forms)).orElse {
      name.split(" ", 2) match
        case Array(route, formName) if routes(route) =>
          Some(route.toUpperCase(java.util.Locale.ROOT) -> Set(formName.toUpperCase(java.util.Locale.ROOT)))
        case _ => None
    }

  case class Component(ingredient: RxConcept, strength: ProductStrength)
  case class Profile(components: Vector[Component], route: String, forms: Set[String], brand: Option[String])
  case class Ingredient(name: String, amount: String, unit: String, denominator: String, denominatorUnit: String,
      sourceKind: String, strengthType: String, base: String):
    private val denominatorText = s"$denominator $denominatorUnit".trim
    val amountText: String = s"$amount $unit" + (if denominatorText.isEmpty then "" else s" / $denominatorText")
    def strength: Option[ProductStrength] =
      if sourceKind != "I" || strengthType.nonEmpty || base != "N" ||
        (denominator.nonEmpty && denominatorUnit.isEmpty) then None
      else ProductStrength.parse(amountText)
  case class Presentation(din: String, drugCode: Int, brandName: String, forms: Vector[String], routes: Vector[String])

  private def only[A](values: Vector[A]): Option[A] = values.distinct match
    case Vector(value) => Some(value)
    case _ => None

  def profile(product: RxConcept, snapshot: RxSnapshot): Option[Profile] =
    val concepts = snapshot.concepts.map(c => c.rxcui -> c).toMap
    val outgoing = snapshot.relations.groupBy(_.source)
    def targets(from: RxConcept, relation: String): Vector[RxConcept] =
      outgoing.getOrElse(from.rxcui, Vector.empty).filter(_.rela == relation).flatMap(r => concepts.get(r.target)).distinct
    def component(c: RxConcept): Option[Component] =
      val strengths = snapshot.attributes.filter(a => a.rxcui == c.rxcui && a.atn == "RXN_STRENGTH").map(a => ProductStrength.parse(a.value))
      for
        ingredient <- only(targets(c, "has_ingredient")).filter(_.tty == "IN")
        if targets(c, "has_precise_ingredient").isEmpty
        strength <- strengths.headOption.flatten
        if strengths.forall(_.exists(_.equivalent(strength)))
      yield Component(ingredient, strength)

    for
      generic <- product.tty match
        case "SCD" => Some(product)
        case "SBD" => only(targets(product, "tradename_of").filter(_.tty == "SCD"))
        case _ => None
      form <- only(targets(product, "has_dose_form")).filter(_.tty == "DF")
      if only(targets(generic, "has_dose_form")).contains(form)
      routeAndForms <- administration(form.display)
      brand = only(targets(product, "has_ingredient").filter(_.tty == "BN")).map(_.display)
      if product.tty != "SBD" || brand.nonEmpty
      parts = targets(generic, "consists_of")
      if parts.nonEmpty && parts.forall(_.tty == "SCDC")
      components = parts.flatMap(component)
      if components.size == parts.size && components.map(_.ingredient.rxcui).distinct.size == components.size
    yield Profile(components, routeAndForms._1, routeAndForms._2, if product.tty == "SBD" then brand else None)

  def candidate(profile: Profile, names: Map[String, Set[String]], presentation: Presentation,
      ingredients: Vector[Ingredient]): Option[CanadianProduct] =
    // Match at word boundaries (e.g. Tylenol Extra Strength), never a partial brand token.
    def tokens(text: String): String = TextKey.normalize(text).split("[^\\p{L}\\p{N}]+").filter(_.nonEmpty).mkString(" ", " ", " ")
    val brandMatches = profile.brand.forall(brand => tokens(presentation.brandName).contains(tokens(brand)))
    val rows = ingredients.distinct
    val matchedComponents = rows.map { row =>
      only(profile.components.filter(c =>
        names.getOrElse(c.ingredient.rxcui, Set.empty).contains(TextKey.normalize(row.name)) &&
          row.strength.exists(_.equivalent(c.strength))).map(_.ingredient.rxcui))
    }
    Option.when(presentation.routes == Vector(profile.route) && presentation.forms.nonEmpty && presentation.forms.forall(profile.forms) &&
      brandMatches && rows.size == profile.components.size && matchedComponents.forall(_.nonEmpty) &&
      matchedComponents.flatten.distinct.size == rows.size) {
      CanadianProduct(presentation.din, presentation.drugCode, presentation.brandName,
        rows.map(r => s"${r.name} ${r.amountText}").sorted, presentation.forms, presentation.routes)
    }
