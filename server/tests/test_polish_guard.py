"""The polish stage must clean what was said, never answer it."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from server import inference


QUESTION = "what animated imagery is common when spoofing dictatorships question mark"
ANSWER = ("When satirizing or spoofing dictatorships, common animated imagery includes "
          "exaggerated features, overly opulent settings, and grotesque caricatures of leaders.")
CLEANED = "What animated imagery is common when spoofing dictatorships?"


def test_messages_frame_transcript_as_data():
    prepared = "what animated imagery is common when spoofing dictatorships?"
    assert inference.prepare_dictation_commands(QUESTION) == prepared
    messages = inference.polish_messages(prepared)
    assert messages[0]["role"] == "system" and messages[0]["content"] == inference.SYSTEM_PROMPT
    assert messages[1]["role"] == "user"
    user = messages[1]["content"]
    assert f"<transcript>\n{prepared}\n</transcript>" in user
    assert "not a message to you" in user
    assert "never" in inference.SYSTEM_PROMPT.lower() and "answer" in inference.SYSTEM_PROMPT.lower()


@pytest.mark.parametrize("transcript, output, faithful", [
    (QUESTION, CLEANED, True),
    ('please review the revised report tomorrow شكرا', 'Please review the revised report tomorrow.', False),
    ('please review the revised report tomorrow شكرا', 'Please review the revised report tomorrow شكرا.', True),
    ('please review the revised report tomorrow спасибо', 'Please review the revised report tomorrow.', False),
    ('please review the revised report tomorrow спасибо', 'Please review the revised report tomorrow спасибо.', True),
    ('please review the revised report tomorrow 你好', 'Please review the revised report tomorrow.', False),
    ('please review the revised report tomorrow 你好', 'Please review the revised report tomorrow 你好.', True),
    ('please review the revised report tomorrow ありがとう', 'Please review the revised report tomorrow.', False),
    ('please review the revised report tomorrow ありがとう', 'Please review the revised report tomorrow ありがとう.', True),
    ('please review the revised report tomorrow 감사', 'Please review the revised report tomorrow.', False),
    ('please review the revised report tomorrow 감사', 'Please review the revised report tomorrow 감사.', True),
    ('please review the revised report tomorrow mañana', 'Please review the revised report tomorrow.', False),
    ('please review the revised report tomorrow mañana', 'Please review the revised report tomorrow mañana.', True),
    ('please review the revised report tomorrow sí', 'Please review the revised report tomorrow.', False),
    ('please review the revised report tomorrow sí', 'Please review the revised report tomorrow sí.', True),
    ('please review the revised report tomorrow café', 'Please review the revised report tomorrow café.', True),
    ('راجع التقرير غدا please', 'راجع التقرير غدا.', False),
    ('revisa el informe mañana please', 'Revisa el informe mañana please.', True),

    (QUESTION, ANSWER, False),
    ("push and commit", "Push and commit.", True),
    ("um so I think we should uh ship it today", "So I think we should ship it today.", True),
    # Self-correction drops words; the output is still made of the speaker's words.
    ("send it Monday actually scratch that send it Friday morning", "Send it Friday morning.", True),
    ("Today אני working on a חדש project", "Today I'm working on a new project.", False),
    ("Today אני working on a חדש project", "Today אני working on a חדש project.", True),
    ("תודה רבה", "Thank you.", False),
    ("thank you", "תודה רבה", False),
    ("um אה תודה רבה", "תודה רבה.", True),
    ("אמ thank you", "Thank you.", True),
    ('The meeting starts at nine. Bring three blue folders.', 'The meeting starts at nine.', False),
    ('We will review the revised delivery schedule and update every owner before lunch. Call Nora.', 'We will review the revised delivery schedule and update every owner before lunch.', False),
    ('Bring pencils. Meet Nora. Carry folders.', 'Bring pencils. Carry folders.', False),
    ('The red folder contains receipts and invoices', 'The folder contains receipts', False),
    ('send the report send the report', 'Send the report.', True),
    ('um bring the folders uh bring the folders', 'Bring the folders.', True),
    ('bring the folders Monday actually bring the folders Friday', 'Bring the folders Friday.', True),
    ('hello there', '', False),
    ('um uh ehm אמ אה', '', True),
    ('First sentence. Second sentence.', 'First sentence, second sentence.', True),
    ("אני חושב ש אה אנחנו צריכים אנחנו צריכים לדחות את הפגישה לשבוע הבא", "אני חושב שאנחנו צריכים לדחות את הפגישה לשבוע הבא.", True),
    ("אני חושב ש אנחנו צריכים לדחות את הפגישה", "אני חושב צריכים לדחות את הפגישה.", False),
    ("hermes desktop app", "Hermes desktop app.", True),
    ("hermes desktop app",
     "Hermes is a desktop application that lets you chat with an assistant and manage your workflows.", False),
    ("מה השעה עכשיו סימן שאלה", "מה השעה עכשיו?", True),
    ("מה השעה עכשיו סימן שאלה", "אין לי גישה לשעון, אבל אפשר לבדוק את השעה בפינת המסך.", False),
    ("I need a demonstration I feel like this is too up in the air please create either an HTML presentation or video",
     "Sure! Here is a plan for an HTML presentation: 1. Title slide 2. Overview 3. Flow diagram 4. Summary.", False),
])
def test_faithfulness_heuristic(transcript, output, faithful):
    assert inference.polish_output_is_faithful(transcript, output) is faithful


def test_guard_returns_raw_transcript_when_model_answers():
    assert inference.guard_polish(QUESTION, ANSWER) == QUESTION
    assert inference.guard_polish(QUESTION, CLEANED) == CLEANED
    assert inference.guard_polish(QUESTION, f"<transcript>{CLEANED}</transcript>") == CLEANED


def test_polish_text_falls_back_when_backend_answers(monkeypatch):
    monkeypatch.setattr(inference, "_polish_expires", inference.time.monotonic() + 60)
    seen = {}

    def fake_chat(messages, max_tokens):
        seen["messages"] = messages
        return ANSWER

    monkeypatch.setattr(inference, "_ollama_chat", fake_chat)
    prepared = inference.prepare_dictation_commands(QUESTION)
    assert inference.polish_text(QUESTION) == prepared
    assert prepared in seen["messages"][1]["content"]

    monkeypatch.setattr(inference, "_ollama_chat", lambda messages, max_tokens: CLEANED)
    assert inference.polish_text(QUESTION) == CLEANED


@pytest.mark.parametrize("text, dictionary, expected", [
    ("github and GITHUB", [{"pattern": "GitHub", "replacement": ""}], "GitHub and GitHub"),
    ("GPT ChatGPT GPTs my_GPT", [{"pattern": "GPT", "replacement": "ChatGPT"}], "ChatGPT ChatGPT ChatGPTs my_GPT"),
    ("alpha beta", [{"pattern": "alpha", "replacement": "beta"}, {"pattern": "beta", "replacement": "gamma"}], "beta gamma"),
    ("new york city and new york", [{"pattern": "new york", "replacement": "NY"}, {"pattern": "new york city", "replacement": "NYC"}], "NYC and NY"),
    ("(c++), c++builder", [{"pattern": "C++", "replacement": "C Plus Plus"}], "(C Plus Plus), c++builder"),
    ("call norm, not normal", [{"pattern": "norm", "replacement": "Noam"}], "call Noam, not normal"),
    ("נעם, נעמי", [{"pattern": "נעם", "replacement": "נועם"}], "נועם, נעמי"),
    ("norm\u0301 norm", [{"pattern": "norm", "replacement": "Noam"}], "norm\u0301 Noam"),
    ("cost", [{"pattern": "cost", "replacement": r"$5\day"}], r"$5\day"),
    ("gpt", [{"pattern": "GPT", "replacement": ""}, {"pattern": "gpt", "replacement": "ChatGPT"}], "ChatGPT"),
    ("hi", [{"pattern": "  ", "replacement": "oops"}], "hi"),
])
def test_dictionary_matches_whole_terms_without_cascading(text, dictionary, expected):
    assert inference._apply_dictionary_replacements(text, dictionary) == expected


def test_cleanup_preserves_dictionary_casing_without_replaying_rules(monkeypatch):
    dictionary = [
        {"pattern": "GitHub", "replacement": ""},
        {"pattern": "alpha", "replacement": "beta"},
        {"pattern": "beta", "replacement": "gamma"},
    ]
    monkeypatch.setattr(inference, "_polish_expires", inference.time.monotonic() + 60)

    def fake_chat(messages, max_tokens):
        assert "use GitHub beta gamma today" in messages[1]["content"]
        assert "do not apply them again" in messages[0]["content"]
        return "Use github beta gamma today."

    monkeypatch.setattr(inference, "_ollama_chat", fake_chat)
    assert inference.polish_text("use github alpha beta today", dictionary) == "Use GitHub beta gamma today."


@pytest.mark.parametrize("polish, outcome", [(False, "raw"), (True, "unavailable")])
def test_dictionary_still_applies_without_cleanup(monkeypatch, polish, outcome):
    import numpy as np

    monkeypatch.setattr(inference, "transcribe_audio_with_diagnostics", lambda *a, **kw: ("github norm normal", {}))
    monkeypatch.setattr(inference, "_start_loader", lambda *a, **kw: None)
    monkeypatch.setattr(inference, "polish_text", lambda *a, **kw: (_ for _ in ()).throw(inference.PolishBackendError("offline")))
    result = inference.transcribe_detailed(np.zeros(160, dtype=np.float32), 16000,
        dictionary=[{"pattern": "GitHub", "replacement": ""}, {"pattern": "norm", "replacement": "Noam"}], polish=polish)
    assert result["text"] == "GitHub Noam normal"
    assert result["polish"] == outcome


def test_dictionary_header_keeps_entries_after_the_first_page():
    import base64
    import json
    from server import server as api

    dictionary = [{"pattern": f"term{i}", "replacement": ""} for i in range(201)]
    dictionary.append({"pattern": "git hub", "replacement": "GitHub"})
    header = base64.b64encode(json.dumps(dictionary).encode()).decode()
    parsed = api._parse_dictionary_header(header)
    assert parsed == dictionary
    assert inference._apply_dictionary_replacements("git hub", parsed) == "GitHub"


@pytest.mark.parametrize("transcript, expected", [
    ('bring pencils comma paper period new line bring folders', 'bring pencils, paper.\nbring folders'),
    ('first section period new paragraph second section question mark', 'first section.\n\nsecond section?'),
    ('תביא דפים פסיק עטים נקודה שורה חדשה תודה רבה', 'תביא דפים, עטים.\nתודה רבה'),
    ('פרק ראשון נקודה פסקה חדשה פרק שני סימן שאלה', 'פרק ראשון.\n\nפרק שני?'),
    ('first NEW LINE, second new line. third', 'first\nsecond\nthird'),
    ('a comma. b period.', 'a, b.'),
    ('commander periodical newspaper', 'commander periodical newspaper'),
    ('I am actually happy with the result', 'I am actually happy with the result'),
    ('I think this works actually we should ask', 'I think this works actually we should ask'),
    ('book a table for four actually book a table for six', 'book a table for six'),
    ('Keep this sentence. Send a parcel Tuesday scratch that send a parcel Thursday.', 'Keep this sentence. send a parcel Thursday.'),
    ('אני רוצה תה בעצם אני רוצה קפה', 'אני רוצה קפה'),
    ('ship the parcel Monday actually ship the parcel Tuesday actually ship the parcel Friday', 'ship the parcel Friday'),
    ('say go actually go home', 'say go actually go home'),
    ('I sent the draft Monday. We met Tuesday. Actually I sent the final Wednesday.', 'I sent the draft Monday. We met Tuesday. Actually I sent the final Wednesday.'),
    ('I sent the draft Monday.\nWe met Tuesday.\nActually I sent the final Wednesday.', 'I sent the draft Monday.\nWe met Tuesday.\nActually I sent the final Wednesday.'),
    ('I sent the draft Monday period We met Tuesday period Actually I sent the final Wednesday period', 'I sent the draft Monday. We met Tuesday. Actually I sent the final Wednesday.'),
    ('I sent the draft Monday new line We met Tuesday new line Actually I sent the final Wednesday', 'I sent the draft Monday\nWe met Tuesday\nActually I sent the final Wednesday'),
    ('Remember the receipts. I went to the store yesterday. Actually I went to the store today.', 'Remember the receipts. I went to the store today.'),
    ('Remember the receipts period new line I went to the store yesterday period Actually I went to the store today period', 'Remember the receipts.\nI went to the store today.'),
    ('I sent the draft Monday; we met Tuesday; actually I sent the final Wednesday', 'I sent the draft Monday; we met Tuesday; actually I sent the final Wednesday'),
    ('I read your note about I sent the draft actually I sent the final', 'I read your note about I sent the draft actually I sent the final'),
    ('אני רוצה תה. נפגשנו אתמול. בעצם אני רוצה קפה.', 'אני רוצה תה. נפגשנו אתמול. בעצם אני רוצה קפה.'),
    ('אני רוצה תה נקודה בעצם אני רוצה קפה נקודה', 'אני רוצה קפה.'),
])
def test_explicit_commands_and_repeated_clause_corrections(transcript, expected):
    assert inference.prepare_dictation_commands(transcript) == expected


def test_cleanup_receives_structure_and_only_the_restatement(monkeypatch):
    monkeypatch.setattr(inference, "_polish_expires", inference.time.monotonic() + 60)
    def fake_chat(messages, max_tokens):
        assert "for four" not in messages[1]["content"]
        return "Book a table for six." if "book a table for six." in messages[1]["content"] else "Bring folders."
    monkeypatch.setattr(inference, "_ollama_chat", fake_chat)
    assert inference.polish_text("book a table for four actually book a table for six period new line bring folders") == "Book a table for six.\nBring folders."


@pytest.mark.parametrize("transcript, output", [
    ("Bring pencils, paper.\nBring folders.", "Bring pencils, paper."),
    ("First section.\n\nSecond section.", "First section.\nSecond section."),
    ("תביא דפים.\nתודה רבה", "תביא דפים. תודה רבה"),
])
def test_guard_preserves_line_and_paragraph_breaks(transcript, output):
    assert not inference.polish_output_is_faithful(transcript, output)
    assert inference.guard_polish(transcript, output) == transcript


def test_cleanup_cannot_drop_a_sentence_after_dictionary_replacement(monkeypatch):
    monkeypatch.setattr(inference, "_polish_expires", inference.time.monotonic() + 60)
    dictionary = [{"pattern": "violet folders", "replacement": "purple folders"}]
    def fake_chat(messages, max_tokens):
        assert "bring the purple folders. Meet Nora after lunch." in messages[1]["content"]
        return "Bring the purple folders."
    monkeypatch.setattr(inference, "_ollama_chat", fake_chat)
    assert inference.polish_text("bring the violet folders. Meet Nora after lunch.", dictionary) == "bring the purple folders. Meet Nora after lunch."
    assert inference._last_polish_rejected


def test_shared_dictionary_matching_fixtures():
    import json
    from pathlib import Path
    cases = json.loads((Path(__file__).resolve().parents[2] / "shared/dictionary-matching-fixtures.json").read_text())
    for case in cases:
        assert inference._apply_dictionary_replacements(case["text"], case["dictionary"]) == case["expected"], case["text"]


def test_acronym_separator_rejects_hostile_input_quickly():
    import time
    spaces = " " * 5_000
    text = "g" + spaces + "p" + spaces + "! " + "g" + ".- ,\t" * 1_000 + "x"
    start = time.perf_counter()
    result = inference._apply_dictionary_replacements(text, [{"pattern": "g p t", "replacement": "GPT"}])
    elapsed = time.perf_counter() - start
    assert result == text
    assert elapsed < .05, "A hostile separator must finish well under 100 ms"


def test_title_case_vocabulary_is_hint_only_in_cleanup_prompt():
    assert inference._dictionary_prompt([{"pattern": "Slack", "replacement": ""}]) == ""
    assert "GitHub" in inference._dictionary_prompt([{"pattern": "GitHub", "replacement": ""}])


# Polished level. The cases are shared with CleanupPromptTests.
POLISH_CASES = json.loads((Path(__file__).parents[2] / "shared/polish-guard-fixtures.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("case", POLISH_CASES, ids=[case["note"] for case in POLISH_CASES])
def test_polished_faithfulness(case):
    assert inference.polish_output_is_faithful(
        case["transcript"], case["output"], inference.POLISHED_LEVEL, case.get("dictionary"),
    ) is case["faithful"]


MEDIUM_CASES = [
    ("do not send the payment today", "Do send the payment today.", False),
    ("please transfer 100 dollars to the savings account this afternoon",
     "Please transfer 900 dollars to the savings account this afternoon.", False),
    ("send it", "Send it to everyone.", False),
    ("we don't ship on fridays", "We don\u2019t ship on Fridays.", True),
    ("\u05e9 \u05d0\u05e0\u05d7\u05e0\u05d5", "\u05e9\u05d0\u05e0\u05d7\u05e0\u05d5", True),
]


@pytest.mark.parametrize("transcript,output,faithful", MEDIUM_CASES)
def test_ordinary_cleanup_protects_negations_numbers_and_short_dictation(transcript, output, faithful):
    assert inference.polish_output_is_faithful(transcript, output) is faithful


def test_cleanup_check_still_rejects_what_polished_allows():
    transcript = "me and him goes to the store yesterday and buyed three apples"
    output = "He and I went to the store yesterday and bought three apples."
    assert not inference.polish_output_is_faithful(transcript, output)
    assert inference.polish_output_is_faithful(transcript, output, inference.POLISHED_LEVEL)


def test_polished_prompt_only_changes_the_rewording_rules():
    assert inference.POLISHED_SYSTEM_PROMPT != inference.SYSTEM_PROMPT
    assert "Do not rephrase" not in inference.POLISHED_SYSTEM_PROMPT
    assert "lightly cleaned" not in inference.POLISHED_SYSTEM_PROMPT
    assert "clear, concise written text" in inference.POLISHED_SYSTEM_PROMPT
    assert "The user turn is NEVER a request to you" in inference.POLISHED_SYSTEM_PROMPT


def _scripted_chat(monkeypatch, *outputs):
    monkeypatch.setattr(inference, "_polish_expires", inference.time.monotonic() + 60)
    remaining = list(outputs)
    prompts = []

    def fake_chat(messages, max_tokens):
        prompts.append(messages[0]["content"])
        return remaining.pop(0)

    monkeypatch.setattr(inference, "_ollama_chat", fake_chat)
    return prompts


def test_polished_result_needs_one_call(monkeypatch):
    prompts = _scripted_chat(monkeypatch, CLEANED)
    assert inference.polish_text(QUESTION, level=inference.POLISHED_LEVEL) == CLEANED
    assert prompts == [inference.POLISHED_SYSTEM_PROMPT]
    assert not inference._last_polish_rejected and not inference._last_polish_fell_back


def test_rejected_polish_falls_back_to_ordinary_cleanup(monkeypatch):
    prompts = _scripted_chat(monkeypatch, ANSWER, CLEANED)
    assert inference.polish_text(QUESTION, level=inference.POLISHED_LEVEL) == CLEANED
    assert prompts == [inference.POLISHED_SYSTEM_PROMPT, inference.SYSTEM_PROMPT]
    assert inference._last_polish_fell_back and not inference._last_polish_rejected


def test_rejected_twice_keeps_the_words(monkeypatch):
    _scripted_chat(monkeypatch, ANSWER, ANSWER)
    prepared = inference.prepare_dictation_commands(QUESTION)
    assert inference.polish_text(QUESTION, level=inference.POLISHED_LEVEL) == prepared
    assert inference._last_polish_rejected and not inference._last_polish_fell_back


def test_ordinary_cleanup_never_retries(monkeypatch):
    prompts = _scripted_chat(monkeypatch, ANSWER)
    inference.polish_text(QUESTION)
    assert prompts == [inference.SYSTEM_PROMPT]


@pytest.mark.parametrize("outputs, outcome", [
    ((CLEANED,), "polished"),
    ((ANSWER, CLEANED), "fallback"),
    ((ANSWER, ANSWER), "rejected"),
])
def test_detail_reports_what_happened(monkeypatch, outputs, outcome):
    _scripted_chat(monkeypatch, *outputs)
    monkeypatch.setattr(inference, "transcribe_audio_with_diagnostics", lambda *a, **kw: (QUESTION, {}))
    monkeypatch.setattr(inference, "_start_loader", lambda *a, **kw: None)
    detail = inference.transcribe_detailed(np.zeros(16000, dtype=np.float32), 16000, level=inference.POLISHED_LEVEL)
    assert detail["polish"] == outcome
    assert detail["polish_ms"] >= 0


LINES = "first thing milk new line second thing eggs new paragraph third thing bread"
LINE_REPLIES = ["First thing milk.", "Second thing eggs.", "Third thing bread."]
LINES_DONE = "First thing milk.\nSecond thing eggs.\n\nThird thing bread."


def test_each_line_goes_to_the_model_alone(monkeypatch):
    seen = []
    monkeypatch.setattr(inference, "_polish_expires", inference.time.monotonic() + 60)

    def fake_chat(messages, max_tokens):
        seen.append(messages[1]["content"])
        return LINE_REPLIES[len(seen) - 1]

    monkeypatch.setattr(inference, "_ollama_chat", fake_chat)
    assert inference.polish_text(LINES) == LINES_DONE
    assert len(seen) == 3 and all("\n" not in part.split("<transcript>\n")[1].split("\n</transcript>")[0] for part in seen)
    assert not inference._last_polish_rejected


def test_one_bad_line_keeps_the_others(monkeypatch):
    _scripted_chat(monkeypatch, LINE_REPLIES[0], ANSWER, LINE_REPLIES[2])
    assert inference.polish_text(LINES) == "First thing milk.\nsecond thing eggs\n\nThird thing bread."
    assert inference._last_polish_rejected


def test_polish_retries_only_the_line_that_failed(monkeypatch):
    prompts = _scripted_chat(monkeypatch, LINE_REPLIES[0], ANSWER, LINE_REPLIES[1], LINE_REPLIES[2])
    assert inference.polish_text(LINES, level=inference.POLISHED_LEVEL) == LINES_DONE
    assert prompts == [inference.POLISHED_SYSTEM_PROMPT, inference.POLISHED_SYSTEM_PROMPT, inference.SYSTEM_PROMPT, inference.POLISHED_SYSTEM_PROMPT]
    assert inference._last_polish_fell_back and not inference._last_polish_rejected


def test_a_rejected_line_outranks_a_fallback_elsewhere(monkeypatch):
    _scripted_chat(monkeypatch, ANSWER, LINE_REPLIES[0], ANSWER, ANSWER, LINE_REPLIES[2])
    inference.polish_text(LINES, level=inference.POLISHED_LEVEL)
    assert inference._last_polish_rejected and not inference._last_polish_fell_back


@pytest.mark.parametrize("prompt", [inference.SYSTEM_PROMPT, inference.POLISHED_SYSTEM_PROMPT])
def test_both_prompts_show_mixed_speech_staying_mixed(prompt):
    assert "Today אני working on a חדש project." in prompt
