package lab

import java.nio.charset.StandardCharsets.US_ASCII
import java.security.{MessageDigest, SecureRandom}
import java.util.HexFormat
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import scala.util.Try
import zio.*
import zio.json.*

private[lab] final case class PreviewProof(sha256: String, token: String)
private[lab] final case class CanadianSelection(release: String, rxcui: String, din: Option[String], preview: Option[PreviewProof])
private[lab] object CanadianSelection:
  def parse(raw: String, requireDin: Boolean, previewRoute: Boolean): Either[ProductSearchFailure,CanadianSelection] =
    Try {
      val params=ProductSearchQuery.parameters(raw)
      val keys = if requireDin then Set("release","rxcui","din") else Set("release","rxcui")
      val preview = if previewRoute && params.keySet == keys ++ Set("sha256","token") then
        val sha=params("sha256")
        val token=params("token")
        require(sha.matches("[0-9a-f]{64}") && token.matches("[0-9a-f]{64}"))
        Some(PreviewProof(sha,token))
      else
        require(params.keySet == keys)
        None
      val release=params("release")
      val rxcui=params("rxcui")
      val din=params.get("din")
      require(ProductSearchQuery.validRelease(release) && rxcui.matches("[1-9][0-9]{0,19}") && din.forall(_.matches("[0-9]{8}")))
      CanadianSelection(release,rxcui,din,preview)
    }.toEither.left.map(_ => ProductSearchFailure(400,"INVALID_CANADIAN_SELECTION","Supply a valid release and RxCUI, plus an eight-digit DIN for document access."))

private[lab] final case class MonographResult(status: String, pdfPath: Option[String] = None,
    sourceUrl: Option[String] = None, sha256: Option[String] = None, revision: Option[String] = None,
    dosagePage: Option[Int] = None) derives JsonCodec

final class CanadianMonographAccess(
    val candidates: (String,String) => Task[CanadianProductCandidates],
    download: (Int,String) => Task[Option[CachedMonograph]],
    cached: (Int,String) => Task[Option[CachedMonograph]]):
  private val previewKey = new SecretKeySpec(new SecureRandom().generateSeed(32),"HmacSHA256")
  private def signature(release: String, rx: String, din: String, hash: String): Array[Byte] =
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(previewKey)
    mac.doFinal(s"$release/$rx/$din/$hash".getBytes(US_ASCII))

  /** VS Code may rewrite the Host header when opening a forwarded port. Only a PDF
    * link signed by this service can authorize that one cached document via the proxy.
    */
  private[lab] def validPreview(release: String, rxcui: String, din: String, proof: PreviewProof): Boolean =
    MessageDigest.isEqual(signature(release,rxcui,din,proof.sha256),HexFormat.of().parseHex(proof.token))

  /** Both fetch and view must use a DIN still associated with this selected product. */
  def document(release: String, rxcui: String, din: String, cacheOnly: Boolean): Task[Option[CachedMonograph]] =
    candidates(release,rxcui).flatMap { response =>
      response.items.find(_.din == din) match
        case None => ZIO.fail(ProductSearchFailure(409,"DIN_NOT_ELIGIBLE","This DIN is not a candidate for the selected RxNorm product. Select it again."))
        case Some(product) =>
          val obtain = if cacheOnly then cached else download
          obtain(product.drugCode,product.din).mapError(_ =>
            ProductSearchFailure(502,"MONOGRAPH_UNAVAILABLE","The official monograph could not be retrieved or verified. Please retry."))
    }

  def confirm(release: String, rxcui: String, din: String): Task[MonographResult] =
    document(release,rxcui,din,cacheOnly = false).flatMap {
      case None => ZIO.succeed(MonographResult("unavailable"))
      case Some(pdf) =>
        val token = HexFormat.of().formatHex(signature(release,rxcui,din,pdf.sha256))
        val localPath=s"/monograph.pdf?release=$release&rxcui=$rxcui&din=$din&sha256=${pdf.sha256}&token=$token"
        ZIO.attemptBlocking(MonographDosage.page(pdf.path)).orElseSucceed(None).map { page =>
          MonographResult("available",Some(localPath),Some(pdf.url),Some(pdf.sha256),pdf.revision,page)
        }
    }
