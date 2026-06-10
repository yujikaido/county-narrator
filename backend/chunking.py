"""Sentence-aware text chunking for TTS.

Greetings are usually a single chunk; longer scripts get split on sentence
boundaries so each piece stays within what the model renders reliably.
"""
import re

MAX_CHARS = 280

# Split after ., !, ? (optionally followed by a closing quote/paren) when the
# next chunk starts with an uppercase letter, digit, quote, or [tag].
_SENTENCE_END = re.compile(r"(?<=[.!?])[\"')\]]*\s+(?=[A-Z0-9\[\"'(])")


def split_text(text: str, max_chars: int = MAX_CHARS) -> list[str]:
    text = " ".join(text.split())
    if not text:
        return []

    sentences = _SENTENCE_END.split(text)
    chunks: list[str] = []
    buf = ""

    for sentence in sentences:
        sentence = sentence.strip()
        if not sentence:
            continue
        if len(sentence) > max_chars:
            if buf:
                chunks.append(buf)
                buf = ""
            chunks.extend(_split_long_sentence(sentence, max_chars))
        elif buf and len(buf) + len(sentence) + 1 > max_chars:
            chunks.append(buf)
            buf = sentence
        else:
            buf = f"{buf} {sentence}".strip()

    if buf:
        chunks.append(buf)
    return chunks


def _split_long_sentence(sentence: str, max_chars: int) -> list[str]:
    """Soft-split an oversized sentence on commas/semicolons, then on words."""
    pieces: list[str] = []
    buf = ""
    for part in re.split(r"(?<=[,;])\s+", sentence):
        if len(part) > max_chars:
            if buf:
                pieces.append(buf)
                buf = ""
            words = part.split()
            for word in words:
                if buf and len(buf) + len(word) + 1 > max_chars:
                    pieces.append(buf)
                    buf = word
                else:
                    buf = f"{buf} {word}".strip()
        elif buf and len(buf) + len(part) + 1 > max_chars:
            pieces.append(buf)
            buf = part
        else:
            buf = f"{buf} {part}".strip()
    if buf:
        pieces.append(buf)
    return pieces
