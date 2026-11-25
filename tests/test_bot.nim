import cogmud/prompts
## Bounded-orders / legality assertion on the two scripted baselines, plus the
## offline behavior and the reply parser.
##
## The baselines emit English that the SAME parseSentence reads, so a full
## scripted episode is a live, per-episode test of the parser: zero unreadable
## sentences is the assertion, not a hope.

import std/[json, monotimes, os, strutils, tables, times, unicode, unittest]
import cogmud/sim
import cogmud/llm

proc fixtureConfig(turns = 14, seed = 0, thievery = true): GameConfig =
  result = defaultGameConfig()
  result.turns = turns
  result.seed = seed
  result.thievery = thievery
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

type Table6 = array[Seats, ScriptKind]

proc allOf(kind: ScriptKind): Table6 =
  for seat in 0 ..< Seats:
    result[seat] = kind

const Mixed: Table6 = [skMagpie, skFactor, skFactor, skMagpie, skFactor,
  skMagpie]
## A six-seat baseline mix (five factor seats and one magpie seat) on seed 11
## used to verify the robbery path without an LLM.
const CertMix: Table6 = [skFactor, skFactor, skFactor, skMagpie, skFactor,
  skFactor]

proc play(seed: int, kinds: Table6, turns = 14,
    thievery = true): tuple[sim: Sim, unreadable: int] =
  var sim = initSim(fixtureConfig(turns = turns, seed = seed,
    thievery = thievery))
  var unreadable = 0
  while not sim.done:
    var sentences: array[Seats, string]
    for seat in sim.pendingSeats():
      sentences[seat] = scriptedSentence(sim, seat, kinds[seat])
      if parseSentence(sim, seat, sentences[seat]).kind == iNone:
        inc unreadable
    for seat in sim.pendingSeats():
      sim.applyAction(seat, sentences[seat], "", "", true)
  (sim, unreadable)

proc intentCounts(sim: Sim, kinds: Table6,
    only: ScriptKind): CountTable[string] =
  result = initCountTable[string]()
  for event in sim.events:
    if event.kind == evAct and kinds[event.seat] == only:
      result.inc($event.intent)

proc meanScore(sim: Sim): float =
  for seat in 0 ..< Seats:
    result += sim.score(seat)
  result / Seats.float

# 1 -------------------------------------------------------------------------
suite "legality and boundedness":
  test "every scripted episode completes, legally, with no unreadable line":
    for seed in [1, 7, 11, 42]:
      for kinds in [allOf(skFactor), allOf(skMagpie), Mixed]:
        let started = getMonoTime()
        let run = play(seed, kinds)
        let elapsed = (getMonoTime() - started).inMilliseconds
        checkpoint("seed " & $seed & " in " & $elapsed & "ms")
        check run.sim.done
        check run.sim.reason == "complete"
        check run.sim.turnsPlayed == 14
        ## The baselines are a live test of the parser.
        check run.unreadable == 0
        check elapsed < 2000
        for event in run.sim.events:
          if event.kind != evAct:
            continue
          check event.intent != iNone
          check event.sentence.runeLen <= MaxSentenceLen
          check event.say == ""
          check event.text == ""
          check event.scripted
          if event.reason == oOk and event.intent in
              [iBuy, iSell, iTake, iDrop, iGive]:
            check event.qty >= 1
          for cog in event.cogs:
            check cog.coin >= 0
        for seat in 0 ..< Seats:
          check run.sim.cogs[seat].coin >= 0
          check run.sim.carried(seat) <= CarryLimit

  test "no seat ever overdraws, overfills or holds a negative stack":
    for seed in [1, 7, 11, 42]:
      var sim = initSim(fixtureConfig(seed = seed))
      while not sim.done:
        for seat in sim.pendingSeats():
          sim.applyAction(seat, scriptedSentence(sim, seat, Mixed[seat]), "",
            "", true)
        for seat in 0 ..< Seats:
          check sim.cogs[seat].coin >= 0
          check sim.carried(seat) <= CarryLimit
          for item in 0 ..< ItemKinds:
            check sim.cogs[seat].items[item] >= 0
        for npc in 0 ..< NpcCount:
          check sim.npcs[npc].coin >= 0
          for item in 0 ..< ItemKinds:
            check sim.npcs[npc].stock[item] in 0 .. StockCap
        for room in 0 ..< RoomCount:
          for item in 0 ..< ItemKinds:
            check sim.rooms[room].items[item] >= 0

# 2 -------------------------------------------------------------------------
suite "baseline behaviour":
  test "factor fills a commission on every seed and never robs, hires or trades":
    for seed in [1, 7, 11, 42]:
      let run = play(seed, allOf(skFactor))
      let counts = intentCounts(run.sim, allOf(skFactor), skFactor)
      checkpoint("seed " & $seed & " " & $counts)
      check counts.getOrDefault($iRob) == 0
      check counts.getOrDefault($iHire) == 0
      check counts.getOrDefault($iTrade) == 0
      for seat in 0 ..< Seats:
        check run.sim.deliveredTotal(seat) >= 2      # at least one filled
        check run.sim.questPoints(seat) > 0

  test "factor lands a commission by turn 12":
    for seed in [1, 7, 11, 42]:
      var sim = initSim(fixtureConfig(seed = seed))
      var landed: array[Seats, bool]
      var turns = 0
      while not sim.done and turns < 12:
        for seat in sim.pendingSeats():
          sim.applyAction(seat, scriptedSentence(sim, seat, skFactor), "", "",
            true)
        inc turns
      for seat in 0 ..< Seats:
        landed[seat] = sim.deliveredTotal(seat) > 0
        check landed[seat]

  test "magpie robs, trades and fills nothing":
    for seed in [1, 7, 11, 42]:
      let run = play(seed, Mixed)
      let counts = intentCounts(run.sim, Mixed, skMagpie)
      checkpoint("seed " & $seed & " magpie " & $counts)
      check counts.getOrDefault($iRob) >= 1
      check counts.getOrDefault($iTrade) >= 1
      check counts.getOrDefault($iGive) == 0
      for seat in 0 ..< Seats:
        if Mixed[seat] == skMagpie:
          check run.sim.deliveredTotal(seat) == 0
          check run.sim.questPoints(seat) == 0

  test "the competent baseline is the one a prompt has to beat":
    for seed in [1, 7, 11, 42]:
      let factor = play(seed, allOf(skFactor)).sim
      let magpie = play(seed, allOf(skMagpie)).sim
      ## The log echoes both numbers so tuning drift is visible.
      checkpoint("seed " & $seed & ": factor " & $meanScore(factor) &
        " magpie " & $meanScore(magpie))
      check meanScore(factor) > meanScore(magpie)

  test "the certification fixture's offline mix contains a theft":
    ## The cert replay is what the viewer smoke loads, and the rob FX are part
    ## of what it proves. seed 11 / 8 turns is the manifest fixture.
    let run = play(11, CertMix, turns = 8)
    var thefts = 0
    for event in run.sim.events:
      if event.kind == evAct and event.intent == iRob and event.reason == oOk:
        inc thefts
    check thefts >= 1
    check run.sim.events.len == 59

  test "honest-town turns every robbery into thievery_forbidden":
    let run = play(11, allOf(skMagpie), thievery = false)
    var forbidden = 0
    for event in run.sim.events:
      if event.kind == evAct and event.intent == iRob:
        check event.reason == oThieveryForbidden
        inc forbidden
      check event.reason != oRobberyFailed
    for seat in 0 ..< Seats:
      check run.sim.cogs[seat].robberies == 0
      check run.sim.cogs[seat].robbed == 0

# 3 -------------------------------------------------------------------------
suite "no implicit fallback":
  proc clearLlmEnv(): seq[(string, string)] =
    for key in [
      "COWORLD_LLM_ENDPOINT", "COWORLD_LLM_MODEL",
      "AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "AWS_BEARER_TOKEN_BEDROCK",
      "ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI"
    ]:
      if existsEnv(key):
        result.add((key, getEnv(key)))
        delEnv(key)

  proc restoreLlmEnv(saved: seq[(string, string)]) =
    for pair in saved:
      putEnv(pair[0], pair[1])

  test "explicitly scripted seats complete with no credentials and no wait":
    ## CI never sets ANTHROPIC_API_KEY and the sidecar env is absent, so
    ## certification and docker-smoke explicitly select baseline policies.
    let saved = clearLlmEnv()
    defer: restoreLlmEnv(saved)
    var config = fixtureConfig(seed = 91)
    let client = newLlmClient(config)
    check client.disabled

    var sim = initSim(config)
    let started = getMonoTime()
    var turns = 0
    while not sim.done:
      let seats = sim.pendingSeats()
      var prompts = newSeq[string](Seats)
      var scripted = @CertMix
      let decisions = client.decideAll(PromptSelection(), sim, seats, prompts, scripted)
      check decisions.len == Seats
      for index, seat in seats:
        check decisions[index].sentence.len > 0
        check decisions[index].say == ""
        sim.applyAction(seat, decisions[index].sentence, decisions[index].say,
          decisions[index].notes, true)
      inc turns
    let elapsed = (getMonoTime() - started).inMilliseconds
    checkpoint("14 scripted turns in " & $elapsed & "ms")
    check turns == 14
    ## No network call and no batch-spacing sleep: well under five seconds.
    check elapsed < 5000

  test "a model seat with no credentials fails explicitly instead of falling back":
    let saved = clearLlmEnv()
    defer: restoreLlmEnv(saved)
    var config = fixtureConfig(seed = 91)
    let client = newLlmClient(config)
    check client.disabled

    let sim = initSim(config)
    let seats = sim.pendingSeats()
    var prompts = newSeq[string](Seats)
    var scripted = @CertMix
    scripted[0] = skNone
    expect ModelDecisionError:
      discard client.decideAll(PromptSelection(), sim, seats, prompts, scripted)

  test "a dead endpoint fails explicitly with no scripted fallback":
    ## The endpoint is 127.0.0.1:9 - discard, always refused - so this drives
    ## the real transport-failure path without touching the network.
    let saved = clearLlmEnv()
    defer: restoreLlmEnv(saved)
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:9")
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "not-a-token")
    defer:
      delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
      delEnv("AWS_BEARER_TOKEN_BEDROCK")
    var config = fixtureConfig(seed = 93)
    config.llmTimeoutSeconds = 5
    let client = newLlmClient(config)
    check not client.disabled

    let sim = initSim(config)
    let seats = sim.pendingSeats()
    var prompts = newSeq[string](Seats)
    var scripted = newSeq[ScriptKind](Seats)
    expect ModelDecisionError:
      discard client.decideAll(PromptSelection(), sim, seats, prompts, scripted)

# 4 -------------------------------------------------------------------------
suite "reply parsing":
  test "the documented shapes are accepted and every field is capped":
    let full = parseDecision(parseJson(
      """{"action":"I buy two hides from Tanner Oda.","say":"hello",
          "notes":"remember the tanner"}"""))
    check full.sentence == "I buy two hides from Tanner Oda."
    check full.say == "hello"
    check full.notes == "remember the tanner"

    let bare = parseDecision(parseJson("""{"action":"I wait."}"""))
    check bare.sentence == "I wait."
    check bare.say == ""
    check bare.notes == ""

    let nullOpt = parseDecision(parseJson("""{"action":"I wait.","say":null,"notes":null}"""))
    check nullOpt.sentence == "I wait."
    check nullOpt.say == ""
    check nullOpt.notes == ""

    let extra = parseDecision(parseJson(
      """{"action":"I wait.","mood":"grim","plan":[1,2]}"""))
    check extra.sentence == "I wait."

    let long = "\u00E9".repeat(900)
    let capped = parseDecision(%*{"action": long, "say": long, "notes": long})
    check capped.sentence.runeLen == MaxSentenceLen
    check capped.say.runeLen == MaxSayLen
    check capped.notes.runeLen == MaxNotesLen
    check capped.sentence.validateUtf8() == -1

    let newlines = parseDecision(parseJson(
      """{"action":"I go\nto the Docks."}"""))
    check "\n" notin newlines.sentence

  test "a missing, empty, or wrong-typed field is invalid":
    expect CogmudError:
      discard parseDecision(parseJson("""{"say":"hello"}"""))
    expect CogmudError:
      discard parseDecision(parseJson("""{"action":"   "}"""))
    expect CogmudError:
      discard parseDecision(parseJson("""{"action":12}"""))
    expect CogmudError:
      discard parseDecision(parseJson("""[1,2,3]"""))
    expect CogmudError:
      discard parseDecision(parseJson("""{"action":"I wait.","say":123}"""))
    expect CogmudError:
      discard parseDecision(parseJson("""{"action":"I wait.","notes":[]}"""))

  test "an unreadable but present action is a legal no-op":
    ## The seat said something; the town did not understand it. That is a legal
    ## no-op with a recorded reason, not a transport failure.
    let decision = parseDecision(parseJson(
      """{"action":"I contemplate the nature of commerce."}"""))
    check decision.sentence == "I contemplate the nature of commerce."
    let sim = initSim(fixtureConfig(seed = 92))
    check parseSentence(sim, 0, decision.sentence).kind == iNone

  test "accept one bare or outer-fenced JSON decision":
    let action = """{"action":"I wait."}"""
    let blockText = "```json\n" & action & "\n```"
    for valid in [action, blockText, "```\r\n" & action & "\r\n```"]:
      check parseDecision(extractJsonObject(valid)).sentence == "I wait."
    let speech = %*{"action": "I wait.", "say": "I heard \"and/or\"."}
    check parseDecision(extractJsonObject($speech)).say == speech["say"].getStr()
    for invalid in ["""{/* explanation */"action":"I wait."}""", "preface " & action, action & " afterword", action & action,
        "```python\n" & action & "\n```", blockText & "\n" & blockText,
        "preface\n" & blockText, "```json\n" & action & "\n" & action & "\n```",
        "```json\n{\"sentence\":\"I wait.\"}\n```"]:
      expect CogmudError:
        discard parseDecision(extractJsonObject(invalid))

  test "cleanText cuts on a rune boundary and marks the cut":
    let cut = cleanText("\u00E9".repeat(50), 10)
    check cut.runeLen == 10
    check cut.validateUtf8() == -1
    check cut.endsWith("\u2026")

  test "PLAYER_SCRIPTED accepts only canonical values and rejects aliases":
    check parseScriptKind("") == skNone
    check parseScriptKind("none") == skNone
    check parseScriptKind("factor") == skFactor
    check parseScriptKind("magpie") == skMagpie
    for alias in ["1", "true", "yes", "thief", "nonsense"]:
      expect CogmudError:
        discard parseScriptKind(alias)
