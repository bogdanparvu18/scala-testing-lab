package lab

import java.nio.file.{Files, Path}

/** Additive RXNSAT import, pinned to the already imported CONSO/REL files. */
final class PreparedProductAttributes private[lab] (
  dir: Path, val release: String, val sha256: Map[String,String]
):
  def foreachRow(consume: Array[String] => Unit): Unit =
    Rrf.rows(dir.resolve("RXNSAT.RRF"),13) { (row, _) => consume(row.take(13)) }
    verifyUnchanged()
  def verifyUnchanged(): Unit = sha256.foreach { (name, hash) =>
    require(Rrf.hash(dir.resolve(name)) == hash,s"RRF input changed since product-attribute preparation: $name")
  }

object ProductAttributes:
  val policy = "single-component-mass-v1"
  def prepare(dir: Path, release: String): PreparedProductAttributes =
    java.time.LocalDate.parse(release)
    val files = Vector("RXNCONSO.RRF","RXNREL.RRF","RXNSAT.RRF")
    files.foreach(name => require(Files.isRegularFile(dir.resolve(name)),s"Missing RRF file: ${dir.resolve(name)}"))
    new PreparedProductAttributes(dir,release,files.map(name => name -> Rrf.hash(dir.resolve(name))).toMap)
