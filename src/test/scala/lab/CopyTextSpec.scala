package lab

import java.nio.charset.StandardCharsets.UTF_8
import zio.test.*

object CopyTextSpec extends ZIOSpecDefault:
  def spec = suite("PostgreSQL COPY transport")(
    test("preserves empty fields, literal escape-looking text, quotes and Unicode") {
      val encoded = new String(CopyText.encodeRow(Vector("", "\\N", "\\.", "a\\tb", "\"quoted\"", "µ😀", "")),UTF_8)
      val expected = "\t\\\\N\t\\\\.\ta\\\\tb\t\"quoted\"\tµ😀\t\n"
      assertTrue(encoded == expected)
    },
    test("escapes embedded tab and line separators into one COPY record") {
      val encoded = new String(CopyText.encodeRow(Vector("a\tb", "line\nnext", "CR\rend")),UTF_8)
      val expected = "a\\tb\tline\\nnext\tCR\\rend\n"
      assertTrue(encoded == expected, encoded.count(_ == '\n') == 1)
    },
    test("rejects null and NUL fields instead of silently changing source data") {
      val nullField = scala.util.Try(CopyText.encodeRow(Vector(null)))
      val nulField = scala.util.Try(CopyText.encodeRow(Vector("x\u0000y")))
      assertTrue(nullField.isFailure,nulField.isFailure)
    }
  )
