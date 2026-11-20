package lab

import java.nio.file.Path
import java.util.Locale
import java.util.regex.Pattern
import scala.util.matching.Regex

/** An intentionally small set of English prose layouts. Each draft is read from one
  * product-labelled source paragraph in an explicit adult, immediate-release section.
  * Tables, paediatric/weight-based rules, titration and unknown schedules remain manual.
  */
private[lab] object MonographRegimen:
  private val number = """[0-9]{1,6}(?:\.[0-9]{1,4})?"""
  private val unit = """(?:mcg|mg|g)"""
  private val adult = """(?i)^adults(?:\s+and\s+(?:children|adolescents)\s+\d{1,2}\s+years(?:\s+of\s+age)?\s+and\s+(?:older|over))?\s*:?$""".r
  private val release = """(?i)^immediate[ -]release\s*:?$""".r
  private val presentation = (s"(?i)^($number)\\s*($unit)\\s+([a-z][a-z /,()-]{0,90}):\\s*(.*)$$").r
  private val ingredient = (s"(?i)^([^/]+?)\\s+($number)\\s*($unit)$$").r
  private val dash = """(?:to|[-–—])"""
  private val administration = (s"(?i)^(?:take\\s+)?($number)\\s*($unit)(?:\\s*$dash\\s*($number)\\s*($unit))?\\s+(?:orally\\s+)?").r
  private val interval = (s"(?i)^every\\s+([1-9][0-9]?)(?:\\s*$dash\\s*([1-9][0-9]?))?\\s+hours?\\b").r
  private val daily = """(?i)^once daily\b""".r
  private val asNeeded = """(?i)^\s*,?\s*as (?:required|needed)\b""".r
  private val ceiling = """(?:not to exceed|do not exceed|not greater than|taken in divided doses, not greater than)"""
  private val period = """(?:per (?:single dose|dose|day)|(?:in|per) (?:any )?24 hours?)"""
  private def limitsFor(ingredientName: String): Regex =
    (s"(?i)^$ceiling\\s+($number)\\s*($unit)(?:\\s+${Pattern.quote(ingredientName)})?\\s+($period)\\.").r
  private val beginsLimit = (s"(?i)^(?:$ceiling|maximum)\\b").r
  private val nextGroup = """(?i)^(?:(?:sustained|extended|delayed)[ -]release\s*:?|children under \d{1,2} years(?: of age)?\s*:.*)$""".r
  private val food = """(?i)^doses may be (?:administered|taken) with or without food\.$""".r
  private val footer = """(?i)^.*\bpage\s+\d+\s+of\s+\d+\s*$""".r
  private val structuralHeading = """(?i)^(?:4\.2\s+)?recommended dose and dosage adjustment\s*:?$""".r
  private val plainFormWords = Set("tablet", "caplet", "capsule", "liquid gel capsule", "sachet")
  private val forms = Map(
    "TABLET" -> Set("tablet", "caplet"), "TABLET (IMMEDIATE-RELEASE)" -> Set("tablet", "caplet"),
    "CAPSULE" -> Set("capsule"), "CAPSULE (IMMEDIATE-RELEASE)" -> Set("capsule")
  )

  def inspect(path: Path, product: CanadianProduct): (Option[Int], Vector[RegimenSuggestion]) =
    val matchProduct = for
      case Vector(ingredient(name, amount, u)) <- Option(product.ingredients)
      strength <- ProductStrength.parse(s"$amount $u")
      case Vector(form) <- Option(product.forms)
      accepted <- forms.get(form)
      if product.routes == Vector("ORAL")
    yield (strength, accepted, limitsFor(name))
    var group = Option.empty[(Int, Vector[String])]
    var following = Option.empty[String]
    val dosagePage = MonographDosage.readSection(path) { (page, lines) =>
      // Restrictive indications and populations can precede a release heading. Only
      // use a group at the start of the professional dosage section. Inspect the next
      // page's first line to avoid silently truncating a passage at a page break.
      val content = lines.filterNot(footer.matches).dropWhile(_.isEmpty)
      if group.nonEmpty then
        following = content.headOption
        following.isEmpty
      else
        val lead = content.dropWhile(s => s.isEmpty || structuralHeading.matches(s))
        if lead.headOption.exists(release.matches) then group = Some((page, lead))
        matchProduct.nonEmpty && (lead.isEmpty || group.isDefined)
    }
    val result = for
      (strength, accepted, limits) <- matchProduct
      (page, lines) <- group
      candidate <- readGroup(page, lines, following, strength, accepted, limits)
    yield candidate
    (dosagePage, result.toVector)

  private def readGroup(page: Int, lines: Vector[String], following: Option[String], strength: ProductStrength,
      accepted: Set[String], limits: Regex): Option[RegimenSuggestion] =
    val start = lines.indexWhere(_.nonEmpty, 1)
    if start < 0 || !adult.matches(lines(start)) then return None
    val context = s"${lines.head.stripSuffix(":")} · ${lines(start).stripSuffix(":")}"
    // Count every matching presentation, even if its dosage is unparseable. A
    // conditional or titration row must not make a neighbouring row look unique.
    val matches = Vector.newBuilder[Option[RegimenSuggestion]]
    var i = start + 1
    var inGroup = true
    while i < lines.size && inGroup do
      lines(i) match
        case line if line.isEmpty || food.matches(line) => i += 1
        case presentation(labelAmount, labelUnit, labelForms, firstLine) =>
          val label = lines(i).takeWhile(_ != ':')
          i += 1
          val continuation = lines.drop(i).takeWhile(line =>
            line.nonEmpty && !line.contains(':') && !adult.matches(line) && !release.matches(line))
          i += continuation.size
          var body = (firstLine +: continuation).mkString(" ")
          // Ceilings may have their own paragraph. Preserve those limits with the
          // instructions. A separate conditional paragraph makes this row manual.
          var next = lines.indexWhere(_.nonEmpty, i)
          while next >= 0 && beginsLimit.findPrefixOf(lines(next)).nonEmpty do
            val extra = lines.drop(next).takeWhile(s => s.nonEmpty && !s.contains(':'))
            if extra.isEmpty then next = -1
            else
              body += " " + extra.mkString(" ")
              i = next + extra.size
              next = lines.indexWhere(_.nonEmpty, i)
          body = body.trim.replaceAll("\\s+", " ")
          val labels = labelForms.toLowerCase(Locale.ROOT).split("""\s*/\s*|\s+or\s+|\s*,\s*""")
          val mentionsForm = labelForms.toLowerCase(Locale.ROOT).split("[^a-z]+").exists(accepted)
          if mentionsForm && ProductStrength.parse(s"$labelAmount $labelUnit").exists(_.equivalent(strength)) then
            val boundary = lines.view.drop(i).find(s => s.nonEmpty && !food.matches(s))
            val finished = boundary match
              case Some(line) => presentation.matches(line) || nextGroup.matches(line)
              case None => following.forall(nextGroup.matches)
            val parsed = Option.when(finished && labels.exists(accepted) && labels.forall(plainFormWords) && body.length <= 650)(body)
              .flatMap(readInstruction(_, strength, limits)).map { (dose, frequency, rule) =>
                RegimenSuggestion(dose, frequency, page, context, s"$label: $body", rule)
              }
            matches += parsed
        case line if nextGroup.matches(line) => inGroup = false
        case _ => return None
    if i == lines.size && !following.forall(nextGroup.matches) then return None
    matches.result() match
      case Vector(candidate) => candidate
      case _ => None

  private def readInstruction(text: String, strength: ProductStrength, limits: Regex): Option[(String, String, RegimenRule)] =
    for
      dose <- administration.findPrefixMatchOf(text)
      amount = dose.group(1)
      u = dose.group(2).toLowerCase(Locale.ROOT)
      lower <- ProductStrength.parse(s"$amount $u")
      if lower.massMg % strength.massMg == 0
      upper <- Option(dose.group(3)) match
        case None => Some(lower)
        case Some(high) => ProductStrength.parse(s"$high ${dose.group(4)}")
      if upper.massMg >= lower.massMg
      schedule <- schedulePrefix(text.substring(dose.end))
      (frequency, minHours, maxHours, tail) = schedule
      prn = asNeeded.findPrefixMatchOf(tail)
      remainder = tail.substring(prn.fold(0)(_.end)).trim
      caps <- ceilings(remainder, limits)
      (single, daily) = caps
      rule = RegimenRule(1, lower.massMg, upper.massMg, minHours, maxHours, prn.nonEmpty, single, daily)
      draftFrequency = if prn.isEmpty then frequency else (if frequency == "QD" then "q24h" else frequency) + " PRN"
      if rule.violations(Some(Dose(BigDecimal(amount), u)), Some(draftFrequency)).isEmpty
    yield (s"$amount $u", draftFrequency, rule)

  private def ceilings(text: String, clause: Regex): Option[(Option[BigDecimal], Option[BigDecimal])] =
    if text == "." then return Some((None, None))
    var tail = text.stripPrefix(",").stripPrefix(".").trim
    var single = Option.empty[BigDecimal]
    var daily = Option.empty[BigDecimal]
    var count = 0
    while tail.nonEmpty && count < 3 do
      clause.findPrefixMatchOf(tail) match
        case Some(m) =>
          ProductStrength.parse(s"${m.group(1)} ${m.group(2)}") match
            case Some(mass) =>
              val limitType = m.group(3).toLowerCase(Locale.ROOT)
              if limitType.endsWith("dose") then single = Some(single.fold(mass.massMg)(_.min(mass.massMg)))
              else daily = Some(daily.fold(mass.massMg)(_.min(mass.massMg)))
            case None => return None
          tail = tail.substring(m.end).trim
          count += 1
        case None => return None
    Option.when(count > 0 && tail.isEmpty)((single, daily))

  private def schedulePrefix(text: String): Option[(String, Int, Int, String)] =
    interval.findPrefixMatchOf(text).flatMap { m =>
      val start = m.group(1).toInt
      val end = Option(m.group(2)).map(_.toInt)
      Option.when(end.forall(_ > start)) {
        ("q" + start + end.fold("")(n => s"-$n") + "h", start, end.getOrElse(start), text.substring(m.end))
      }
    }.orElse(daily.findPrefixMatchOf(text).map(m => ("QD", 24, 24, text.substring(m.end))))
