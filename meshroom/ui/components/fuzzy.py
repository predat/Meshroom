from PySide6.QtCore import QObject, Slot

# Score of a matched character, and the bonuses it gets from its position in the text
MATCH_SCORE = 1
WORD_START_BONUS = 10  # First character, or after a non-alphanumeric one
CAMEL_CASE_BONUS = 9  # Upper case after a lower case, or a digit after a letter
CONSECUTIVE_BONUS = 4  # Follows the previous match (when not already on a boundary)
GAP_PENALTY = 1  # Per gap between two matches
GAP_CHAR_PENALTY = 0.1  # Per character skipped, before the first match included
RECENT_BONUS = 4


def _boundaryBonus(text, i):
    """ Bonus of the character at index i for being at the start of a word or of a camelCase part. """
    if i == 0 or not text[i - 1].isalnum():
        return WORD_START_BONUS
    prev, char = text[i - 1], text[i]
    if (prev.islower() and char.isupper()) or (prev.isalpha() and char.isdigit()):
        return CAMEL_CASE_BONUS
    return 0


def fuzzyMatch(query, text):
    """
    Match the characters of query, in order and case-insensitively, against text.

    The best-scored alignment is found by dynamic programming, in O(len(query) * len(text)),
    after a cheap subsequence check that rejects most texts.

    Args:
        query (str): the characters to look for.
        text (str): the text to match.

    Returns:
        tuple: (score, indices of the matched characters in text), or None if query is not a subsequence of text.
    """
    if not query:
        return 0, []
    q, t = query.lower(), text.lower()
    # Subsequence check
    position = -1
    for char in q:
        position = t.find(char, position + 1)
        if position < 0:
            return None

    bonuses = [_boundaryBonus(text, i) for i in range(len(text))]
    NONE = float("-inf")
    # scores[i]: best score with the current query character matched at i; origins[j][i]: previous match index
    scores = [MATCH_SCORE + bonuses[i] - GAP_CHAR_PENALTY * i if char == q[0] else NONE for i, char in enumerate(t)]
    origins = []
    for j in range(1, len(q)):
        previous = scores
        scores = [NONE] * len(t)
        origin = [-1] * len(t)
        # Best "previous[k] + GAP_CHAR_PENALTY * k" for k < i - 1: a gap from k costs the characters in between
        bestGap, bestGapIndex = NONE, -1
        for i in range(1, len(t)):
            if i >= 2 and previous[i - 2] + GAP_CHAR_PENALTY * (i - 2) > bestGap:
                bestGap, bestGapIndex = previous[i - 2] + GAP_CHAR_PENALTY * (i - 2), i - 2
            if t[i] != q[j]:
                continue
            consecutive = previous[i - 1] + max(bonuses[i], CONSECUTIVE_BONUS)
            gap = bestGap - GAP_PENALTY - GAP_CHAR_PENALTY * (i - 1) + bonuses[i]
            if consecutive >= gap and consecutive > NONE:
                scores[i], origin[i] = MATCH_SCORE + consecutive, i - 1
            elif gap > NONE:
                scores[i], origin[i] = MATCH_SCORE + gap, bestGapIndex
        origins.append(origin)

    score = max(scores)
    i = scores.index(score)
    indices = [i]
    for origin in reversed(origins):
        i = origin[i]
        indices.append(i)
    indices.reverse()
    return score, indices


def fuzzySearch(query, texts, boostedIndices=(), limit=0):
    """
    Score each text against query and sort the matches.

    Args:
        query (str): the characters to look for.
        texts (list[str]): the texts to search.
        boostedIndices (iterable[int]): indices of texts getting the recent bonus.
        limit (int): maximum number of results (0: all).

    Returns:
        list[dict]: {"index", "score", "matches"} by decreasing score, then by shorter text.
    """
    boosted = set(boostedIndices)
    results = []
    for index, text in enumerate(texts):
        match = fuzzyMatch(query, text)
        if match is None:
            continue
        score, matches = match
        if index in boosted:
            score += RECENT_BONUS
        results.append({"index": index, "score": score, "matches": matches})
    results.sort(key=lambda r: (-r["score"], len(texts[r["index"]]), r["index"]))
    return results[:limit] if limit > 0 else results


class FuzzyMatcher(QObject):
    """ QML access to the fuzzy search (command palette). """

    @Slot(str, "QVariantList", "QVariantList", int, result="QVariantList")
    def search(self, query, texts, boostedIndices, limit):
        return fuzzySearch(query, texts, boostedIndices, limit)
