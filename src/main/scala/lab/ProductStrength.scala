package lab

/** Exact mass or mass/volume comparison. Administered dose is never an input. */
final case class ProductStrength(massMg: BigDecimal, volumeMl: Option[BigDecimal]):
  def equivalent(other: ProductStrength): Boolean = (volumeMl, other.volumeMl) match
    case (None, None) => massMg == other.massMg
    case (Some(a), Some(b)) => massMg * b == other.massMg * a
    case _ => false

object ProductStrength:
  private val syntax = "(?i)^\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(mcg|mg|g)(?:\\s*/\\s*(?:([0-9]+(?:\\.[0-9]+)?)\\s*)?(ml))?\\s*$".r
  def parse(text: String): Option[ProductStrength] =
    if text.length > 100 then None
    else text match
      case syntax(number, unit, denominator, volumeUnit) =>
        val value = BigDecimal(number)
        val mass = unit.toLowerCase(java.util.Locale.ROOT) match
          case "g" => value * BigDecimal(1000)
          case "mcg" => value / BigDecimal(1000)
          case _ => value
        val volume = Option(volumeUnit).map(_ => Option(denominator).map(BigDecimal(_)).getOrElse(BigDecimal(1)))
        Option.when(mass > 0 && volume.forall(_ > 0))(ProductStrength(mass, volume))
      case _ => None
