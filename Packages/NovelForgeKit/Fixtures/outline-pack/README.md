Generated from the platform working copy. context-assembler.service.ts, catalog.service.ts, canon-guard.ts and chapter-plan.service.ts have no uncommitted edits.
chapter-plan.service.ts also imports model-router.service.ts, ai/prompts/index.ts and ai/prompts/types.ts, which are among the 27 edited files; they only feed the stubbed model call and the prompt key, and nothing in the fixture is read from them.
Database access that drizzle expressions would resolve (nearestVolumeKey, loadPlanState) is stubbed from the same world; plan scenarios run ChapterPlanService.plan up to its model call and read the prompt variables.
Continuation states list their keys in code-unit order, as the vault renders them.
Scenarios with `retrieval` give the assembler a stub retrieval service that answers with the scenario's hits (or rejects) and records each query; retrieval.service.ts itself is not run, so the scenarios pin the query, the two sections and their place under the budget, not the ranking.
