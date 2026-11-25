## Opt-in private evidence for the unchanged simultaneous native decisions.
import std/[json, options, os]
import bitworld/decision_trajectory
import curly
import sim, prompts
export decision_trajectory

proc initNativeTrajectory*(config: GameConfig): DecisionTrajectory =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return nil
  newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"), "cogmud-" & $config.seed,
    "cogmud", getEnv("COWORLD_GAME_VERSION"), getEnv("COWORLD_SOURCE_REVISION"))

proc nativeAttempt*(policy: string, turn, seat: int, body: string): DecisionAttempt =
  result = newDecisionAttempt($turn & "-" & $seat & "-attempt-0", policy, aoModel)
  result.request = parseJson(body)
  result.prompt = %*[{"role": "system", "content": result.request["system"]}]
  for message in result.request["messages"]: result.prompt.add(copy(message))
  result.decoder = newJObject()
  for key, value in result.request:
    if key notin ["model", "system", "messages", "anthropic_version"]:
      result.decoder[key] = copy(value)

proc receiveNativeHeaders*(attempt: var DecisionAttempt, response: Response) =
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    let value = response.headers[header]
    if value.len > 0:
      case field
      of "call": attempt.platformCallId = some(value)
      of "model": attempt.modelIdentity = some(value)
      of "tokenizer": attempt.tokenizerIdentity = some(value)
      of "template": attempt.chatTemplateSha256 = some(value)

proc receiveNativeMessage*(attempt: var DecisionAttempt, payload: JsonNode, text: string) =
  if payload.hasKey("model") and payload["model"].kind == JString:
    attempt.model = some(payload["model"].getStr())
  if payload.hasKey("stop_reason") and payload["stop_reason"].kind == JString:
    attempt.stopReason = some(payload["stop_reason"].getStr())
  let usage = payload{"usage"}
  if not usage.isNil and usage.kind == JObject:
    if usage.hasKey("input_tokens") and usage["input_tokens"].kind == JInt: attempt.inputTokens = some(usage["input_tokens"].getInt())
    if usage.hasKey("output_tokens") and usage["output_tokens"].kind == JInt: attempt.outputTokens = some(usage["output_tokens"].getInt())
  attempt.response = %text

proc recordAppliedDecision*(trajectory: DecisionTrajectory, eventIndex, seat: int,
    policy: string, observation, applied: JsonNode, declaredScripted: bool,
    evidence: seq[DecisionAttempt], selection: PromptSelection) =
  if trajectory.isNil: return
  var attempts = evidence
  var selected = none(string)
  var status = asAccepted
  if declaredScripted:
    var attempt = newDecisionAttempt($eventIndex & "-" & $seat & "-baseline", policy, aoUnknown)
    attempt.parsedAction = applied
    attempt.accepted = true
    attempts = @[attempt]
    selected = some(attempt.attemptId)
  else:
    doAssert attempts.len > 0
    if attempts[^1].parsedAction != applied:
      attempts[^1].accepted = false
      attempts[^1].rejectionReason = some("native engine normalized the proposal")
    if attempts[^1].accepted: selected = some(attempts[^1].attemptId)
    else: status = asRejected
  var view = copy(observation)
  view["prompt_attempts"] = newJArray()
  for attempt in attempts:
    if attempt.origin == aoModel:
      view["prompt_attempts"].add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": promptMetadata(selection, attempt.request["system"].getStr(),
          attempt.request["messages"][0]["content"].getStr())})
  trajectory.recordDecision("event-" & $eventIndex, $seat, view, attempts,
    selected, applied, status)

proc recordFailedDecision*(trajectory: DecisionTrajectory, eventIndex, seat: int,
    observation: JsonNode, evidence: seq[DecisionAttempt],
    selection: PromptSelection, reason: string, status: ActionStatus) =
  if trajectory.isNil: return
  var attempts = evidence
  for attempt in attempts.mitems:
    attempt.accepted = false
    if attempt.rejectionReason.isNone:
      attempt.rejectionReason = some(reason)
  var view = copy(observation)
  view["prompt_attempts"] = newJArray()
  for attempt in attempts:
    if attempt.origin == aoModel:
      view["prompt_attempts"].add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": promptMetadata(selection, attempt.request["system"].getStr(),
          attempt.request["messages"][0]["content"].getStr())})
  trajectory.recordDecision("event-" & $eventIndex & "-failed-" & $seat, $seat,
    view, attempts, none(string), newJNull(), status, terminal = true)

proc finishNativeTrajectory*(trajectory: DecisionTrajectory, outcome: JsonNode) =
  if trajectory.isNil: return
  var scores = newJObject()
  for seat in 0 ..< Seats: scores[$seat] = outcome["scores"][seat]
  trajectory.finish(if outcome["reason"].getStr() == "complete":
    esCompleted else: esTruncated, outcome, scores)
  trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))

proc finishFailedNativeTrajectory*(trajectory: DecisionTrajectory,
    failureOutcome: JsonNode) =
  if trajectory.isNil: return
  trajectory.finish(esFailed, failureOutcome, newJObject())
  trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
