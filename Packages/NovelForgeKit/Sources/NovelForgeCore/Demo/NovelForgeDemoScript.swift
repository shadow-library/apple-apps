import ShadowAI
import ShadowCore

extension NovelForgeDemo {
  /// The demo model's answers about the sample novel: chat replies by a phrase of the author's (each absent from the turn's own rules and story context), the plan of chapter 2, drafts of chapters 1 and 2 with their
  /// judge passes, reviews, finalize reads and Story Bible updates. A rule's replies go in turn, so a second chapter gets the second draft.
  public static let script = DemoScript(rules: structuredRules + chatRules + [judgeRule], fallback: fallback)

  static let fallback = "This is the demo of Novel Forge: its answers come from a short script about the sample novel, The Salt Clock."

  static var structuredRules: [DemoRule] {
    [
      rule(chapterPlanSchemaName, secondPlan),
      rule(
        chapterGenerationSchemaName, draft(title: firstChapterTitle, body: firstChapter, summary: firstChapterSummary, state: firstState),
        draft(title: secondChapterTitle, body: secondChapter, summary: secondChapterSummary, state: secondState)),
      rule(chapterExpandSchemaName, ["body": .string(firstChapter)], ["body": .string(secondChapter)]),
      rule(chapterTitleSchemaName, ["title": .string(firstChapterTitle), "alternatives": ["The Tide Bell", "Ninety-One Steps"]]),
      rule(editorialReviewSchemaName, editorialReview),
      rule(continuitySchemaName, firstContinuity, secondContinuity),
      rule(canonRefreshSchemaName, firstRefresh, ["updates": []]),
      rule(chapterSummarizeSchemaName, ["summary": .string(firstChapterSummary), "state": firstState], ["summary": .string(secondChapterSummary), "state": secondState]),
      rule(chatTitleSchemaName, ["title": "Planning the slow clock"]),
      rule(
        chatCompactSchemaName,
        [
          "summary":
            "The author and Forge discussed The Salt Clock: Ines finds the harbour clock eleven minutes slow, Teodor is a suspect who turns ally, and chapter 2 brings the harbour ledger."
        ]),
    ]
  }

  static var chatRules: [DemoRule] {
    [
      chat(
        phrase: "happen next",
        "Chapter 1 is briefed and ready to write. For chapter 2, I would bring Teodor up the stairs: he is the footsteps, and he arrives with the harbour ledger rather than an accusation. Use **Plan chapter 2** below and I will draft the brief."
      ),
      chat(
        phrase: "tell me about",
        "Ines is the heart of it: careful, proud of the tower, and shaken to find her own handwriting on a year of lies. Teodor works best if the reader suspects him through chapter 2. He is hunting the same cheat from the harbour side and cannot read a clock."
      ),
      chat(
        phrase: "culprit",
        "Keep the answer off the page for now. Whoever is buying the minutes needs a boat that profits from coming in first, so the harbour ledger in chapter 2 is where the reader should start looking."
      ),
      chat(
        phrase: "brainstorm",
        "Three directions for the middle of the book: the shim is left in place so Ines can watch who comes in first; a second shim turns up in the church clock; or Hale, her old master, knew all along. The first keeps the mystery fair and gives Ines a choice to make."
      ),
      chat(
        schema: chatRefineSchemaName,
        "Happy to help with The Salt Clock. The outline has the first volume, The Slow Hour, and chapter 1 is briefed: Ines finds the clock eleven minutes slow. Open chapter 1 and choose **Generate** to write it, or ask me to plan chapter 2.",
        "That fits the story. The clock is the town's shared measure, so every scene where someone trusts the bell is a scene where the reader can feel the cost of the lie.",
        "Good question. I would keep the sea in every scene: the tide sets the deadline, and the bell decides who wins the race to the market."),
    ]
  }

  static let judgeRule = DemoRule(DemoMatch(task: .review), replies: [.json(judgePass)])

  static var judgePass: JSONValue {
    let compliant: JSONValue = ["compliant": true, "issues": []]
    return [
      "verdict": "consistent", "findings": [], "readabilityCompliance": compliant, "briefCompliance": compliant, "knowledgeCompliance": compliant,
      "endingCompliance": compliant,
    ]
  }

  private static func rule(_ schema: String, _ replies: JSONValue...) -> DemoRule {
    DemoRule(DemoMatch(schema: schema), replies: replies.map(DemoReply.json))
  }

  private static func chat(phrase: String? = nil, schema: String = chatRefineSchemaName, _ replies: String...) -> DemoRule {
    DemoRule(DemoMatch(task: .chat, schema: schema, phrase: phrase), replies: replies.map { .json(["reply": .string($0)]) })
  }

  private static func draft(title: String, body: String, summary: String, state: JSONValue) -> JSONValue {
    ["title": .string(title), "body": .string(body), "summary": .string(summary), "state": state]
  }

  static var firstState: JSONValue {
    [
      "openConflict": "Someone has been slowing the tide clock and is climbing the stairs now.",
      "characterPositions": [["entityKey": .string(protagonist), "location": "the clock room"]],
      "lastBeat": "Ines closes her hand around the shim and turns down the lantern.", "emotionalState": "Afraid and very still",
    ]
  }

  static var secondState: JSONValue {
    [
      "openConflict": "Whether to remove the shim now or leave it and watch who profits from the late tide.",
      "characterPositions": [["entityKey": .string(protagonist), "location": "the clock room"], ["entityKey": .string(harbourmaster), "location": "the clock room"]],
      "lastBeat": "Teodor opens the ledger to the last page and waits for Ines to decide.", "emotionalState": "Wary, but no longer alone",
    ]
  }

  static var secondPlan: JSONValue {
    [
      "title": .string(secondChapterTitle),
      "objective": "Teodor finds Ines in the clock room, turns from suspect to uneasy ally and gives her the harbour ledger.",
      "scenes": [
        [
          "summary": "Teodor reaches the clock room and finds Ines with the log open.", "pov": .string(protagonist), "goal": "Find out whether Teodor slowed the clock",
          "obstacle": "He has read every page of her log", "turn": "He has been hunting the same cheat for a year",
          "beats": ["The footsteps stop", "Teodor in the doorway", "The log"],
          "estimatedWords": 350,
        ],
        [
          "summary": "Ines shows him the shim and he gives her the harbour ledger.", "pov": .string(protagonist), "goal": "Decide what to do about the shim",
          "obstacle": "Removing it warns whoever is buying the minutes", "turn": "Ines must choose before the bell rings", "beats": ["The shim", "The green ledger", "The choice"],
          "estimatedWords": 350,
        ],
      ],
      "requiredContext": [.string("entity:\(protagonist)"), .string("entity:\(harbourmaster)"), .string("thread:\(slowClock)")],
      "endingContract": [
        "hookType": "turn", "emotionalBeat": "A choice with no safe answer", "openQuestion": "Will Ines leave the shim in and let the boats go out late once more?",
        "handoffState": "Ines and Teodor in the clock room with the ledger open, minutes before the tide bell", "mustNotResolve": [.string("thread:\(slowClock)")],
      ],
      "knowledgeContract": ["pov": [.string(protagonist)]],
      "chapterPurpose": "Turn the harbourmaster from suspect to ally and hand Ines the means to find the buyer.", "readerValue": ["relationship_change", "new_information"],
    ]
  }

  static var editorialReview: JSONValue {
    [
      "disposition": "approve",
      "note": "A clean, tense opening. The clock room is concrete and the eleven minutes land as a real stake. Keep Teodor ambiguous a little longer.",
      "findings": [
        [
          "severity": "suggestion", "text": "The log discovery could carry one more beat of disbelief before Ines checks the escapement.",
          "evidence": "Ines set the log down very gently, as if it might go off.",
        ]
      ],
      "proofreading": [],
    ]
  }

  static var firstContinuity: JSONValue {
    [
      "milestones": [["milestoneKey": .string(shimFound), "reached": true, "evidence": "Ines closed her hand around the brass shim and turned down the lantern."]],
      "appeared": [.string(protagonist)], "newEntities": [],
      "threads": [["threadKey": .string(slowClock), "status": "open", "summary": "The tower clock has been slowed by eleven minutes on purpose.", "confidence": "high"]],
      "mysteries": [], "timeline": [["whenText": "Before dawn", "event": "Ines finds the harbour clock eleven minutes slow and a brass shim behind the spring."]],
      "relationships": [], "power": [],
      "characterStates": [
        [
          "entityKey": .string(protagonist), "location": "the clock room", "immediateGoal": "Hide from whoever is climbing the stairs",
          "evidence": "Ines closed her hand around the brass shim and turned down the lantern.", "confidence": "high",
        ]
      ],
      "knowledgeChanges": [], "chapterSummary": .string(firstChapterSummary),
    ]
  }

  static var secondContinuity: JSONValue {
    [
      "appeared": [.string(protagonist), .string(harbourmaster)], "newEntities": [], "threads": [], "mysteries": [], "timeline": [], "power": [],
      "relationships": [
        [
          "entityKey": .string(protagonist), "targetKey": .string(harbourmaster), "kind": "uneasy allies", "evidence": "I cannot read a clock. You can.",
          "confidence": "high",
        ]
      ],
      "characterStates": [], "knowledgeChanges": [], "chapterSummary": .string(secondChapterSummary),
    ]
  }

  static var firstRefresh: JSONValue {
    [
      "updates": [
        [
          "finding": "Ines now carries the brass shim she found behind the pendulum spring; her record does not say so.",
          "evidence": [["ref": "chapter:1", "quote": "Ines closed her hand around the brass shim and turned down the lantern."]],
          "changeSet": [
            [
              "op": "entity.upsert", "entityKey": .string(protagonist), "type": "character",
              "status": "Apprentice keeper of the harbour clock; carries the brass shim from the pendulum spring",
            ]
          ],
        ]
      ]
    ]
  }
}
