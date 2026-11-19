package lab

import java.util.Locale
import scala.util.Try
import zio.json.*

final case class RegimenViolation(field: String, message: String) derives JsonCodec

/** Inclusive constraints read from a single verified dosage paragraph, in mg and hours. */
final case class RegimenRule(version: Int, minDoseMg: BigDecimal, maxDoseMg: BigDecimal,
    minHours: Int, maxHours: Int, asNeeded: Boolean, maxSingleMg: Option[BigDecimal],
    maxDailyMg: Option[BigDecimal]) derives JsonCodec:

  private def number(mg: BigDecimal): String = mg.bigDecimal.stripTrailingZeros.toPlainString
  private def doseText =
    if minDoseMg == maxDoseMg then s"${number(minDoseMg)} mg"
    else s"${number(minDoseMg)}–${number(maxDoseMg)} mg"
  private def frequencyText =
    val hours = if minHours == maxHours then minHours.toString else s"$minHours–$maxHours"
    s"every $hours hours" + (if asNeeded then " as needed (PRN)" else " on a regular schedule")

  /** Missing fields are handled by the grammar. Only compare values supplied by the clinician. */
  def violations(dose: Option[Dose], frequency: Option[String]): Vector[RegimenViolation] =
    val findings = Vector.newBuilder[RegimenViolation]
    val mass = dose.flatMap { value =>
      // Decimal point shifts convert units exactly, including fractional micrograms.
      value.unit.toLowerCase(Locale.ROOT) match
        case "mg" => Some(value.amount)
        case "g" => Try(BigDecimal(value.amount.bigDecimal.scaleByPowerOfTen(3))).toOption
        case "mcg" => Try(BigDecimal(value.amount.bigDecimal.scaleByPowerOfTen(-3))).toOption
        case _ => None
    }
    def doseAllowed(mg: BigDecimal) =
      mg >= minDoseMg && mg <= maxDoseMg && maxSingleMg.forall(mg <= _) && maxDailyMg.forall(mg <= _)
    if dose.isDefined && !mass.exists(doseAllowed) then
      val single = maxSingleMg.fold("")(n => s" Maximum per dose: ${number(n)} mg.")
      val daily = maxDailyMg.fold("")(n => s" Maximum per 24 hours: ${number(n)} mg.")
      findings += RegimenViolation("dose", s"The dosage passage specifies $doseText per administration.$single$daily")

    val interval = frequency.filter(f => !f.trim.equalsIgnoreCase("QD") || (minHours == 24 && maxHours == 24))
      .flatMap(RegimenRule.hourInterval)
    val allowed = interval.filter { (start, end, prn) =>
      start >= minHours && start <= end && end <= maxHours && prn == asNeeded
    }
    if frequency.isDefined && allowed.isEmpty then
      findings += RegimenViolation("frequency", s"The dosage passage specifies $frequencyText.")

    // PRN describes a minimum separation. Its permitted number of administrations
    // may be lower than the maximum possible at that interval. A fixed scheduled
    // order has no such discretion and must respect the rolling 24-hour ceiling.
    for
      mg <- mass.filter(doseAllowed)
      case (start, _, false) <- allowed
      ceiling <- maxDailyMg if mg * ((24 + start - 1) / start) > ceiling
    do
      val message = s"This dose and scheduled interval can exceed the passage's limit of ${number(ceiling)} mg in 24 hours."
      findings += RegimenViolation("dose", message)
      findings += RegimenViolation("frequency", message)
    findings.result()

object RegimenRule:
  private val interval = """Q?([1-9][0-9]?)(?:-([1-9][0-9]?))?H( PRN)?""".r

  private def hourInterval(frequency: String): Option[(Int, Int, Boolean)] =
    frequency.trim.toUpperCase(Locale.ROOT) match
      case "QD" => Some((24, 24, false))
      case interval(start, end, prn) =>
        val lo = start.toInt
        val hi = Option(end).fold(lo)(_.toInt)
        Option.when(end == null || hi > lo)((lo, hi, prn != null))
      case _ => None
