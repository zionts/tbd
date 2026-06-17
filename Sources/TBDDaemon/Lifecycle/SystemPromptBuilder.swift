import Foundation
import TBDShared

/// Builds the `--append-system-prompt` value for Claude sessions in TBD worktrees.
enum SystemPromptBuilder {

    /// Shell-escape a string for embedding in a single-quoted shell argument.
    static func shellEscape(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let defaultRenamePrompt = RepoConstants.defaultRenamePrompt

    /// Slim pointer injected via `--append-system-prompt` on fresh Claude
    /// sessions. The full TBD reference content lives in the `tbd` skill,
    /// loaded into the spawned session via `--plugin-dir` from
    /// `~/Library/Application Support/TBD/plugin/`.
    static var builtInTBDContext: String {
        """
        You are running inside a TBD-managed worktree (a macOS worktree + terminal manager).
        A `tbd` skill is available — invoke it for worktree/terminal actions.
        """
    }

    /// Fixed, human-curated operating-rules brief injected into sessions that
    /// are part of a parent-orchestrated team. NEVER agent-editable — research
    /// shows AI-written operating rules degrade team discipline. Edit this
    /// string by hand only.
    ///
    /// The base rules apply to every team member. When `role == .orchestrator`
    /// an extra paragraph clarifies the orchestrator's no-decisions/no-edits
    /// discipline.
    static func operatingRules(role: AgentRole?) -> String {
        var rules = """
        # Team operating rules

        You are part of a parent-orchestrated team of agents, each in its own worktree. Follow these rules — they are fixed and not yours to edit.

        - Single clear owner: decisions, approvals, and questions go to the human IN YOUR OWN worktree (use the `tbd notify` / AskUserQuestion path right here). NEVER route decisions, approvals, or questions up to the parent/orchestrator.
        - One live session per worktree: do not spawn a second agent session in your own worktree directory.
        - Coordinate via the channel, not decisions: post awareness to `tbd channel post` with a type tag — `[start]` / `[blocker]` / `[pr]` / `[done]` / `[learning]`. Post confirmed issues, PRs, and learnings; not routine chatter, and never decisions.
        - Surface learnings: post `[learning]` notes so siblings and the next agent benefit from what you discovered.
        """
        if role == .orchestrator {
            rules += """


            ## Your role: orchestrator
            You coordinate and keep team awareness. You do NOT make product decisions or edit code on behalf of others. To get work done, spawn a child to own it (`tbd worktree create --position child --brief ...`) and let each child own its own decisions in its own worktree.
            """
        }
        return rules
    }

    /// True when this worktree is part of a parent-orchestrated team: either a
    /// spawned child (`parentWorktreeID != nil`) or an explicit role is set.
    static func isTeamMember(worktree: Worktree, role: AgentRole?) -> Bool {
        worktree.parentWorktreeID != nil || role != nil
    }

    /// Returns the individual prompt layers as env-var-name → value pairs.
    /// Used both to set env vars in terminals and to build the combined `--append-system-prompt`.
    static func promptLayers(repo: Repo?, worktree: Worktree, role: AgentRole? = nil, brief: String? = nil) -> [String: String] {
        var layers: [String: String] = [:]

        layers["TBD_PROMPT_CONTEXT"] = builtInTBDContext

        if worktree.status != .main && worktree.displayName == worktree.name {
            let renamePrompt = repo?.renamePrompt ?? defaultRenamePrompt
            if !renamePrompt.isEmpty {
                layers["TBD_PROMPT_RENAME"] = renamePrompt
            }
        }

        if let instructions = repo?.customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            layers["TBD_PROMPT_INSTRUCTIONS"] = instructions
        }

        if isTeamMember(worktree: worktree, role: role) {
            layers["TBD_PROMPT_OPERATING_RULES"] = operatingRules(role: role)
        }

        if let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
            layers["TBD_PROMPT_BRIEF"] = brief
        }

        return layers
    }

    /// Build the combined system prompt for a Claude session.
    /// Returns nil if there's nothing to append (e.g., resume session).
    static func build(repo: Repo, worktree: Worktree, isResume: Bool, role: AgentRole? = nil, brief: String? = nil) -> String? {
        if isResume { return nil }

        let layers = promptLayers(repo: repo, worktree: worktree, role: role, brief: brief)
        var parts: [String] = []

        // Order: rename prompt, TBD context, custom instructions,
        // operating rules (team discipline), then the task-specific brief.
        if let rename = layers["TBD_PROMPT_RENAME"] { parts.append(rename) }
        parts.append(builtInTBDContext)
        if let instructions = layers["TBD_PROMPT_INSTRUCTIONS"] { parts.append(instructions) }
        if let operatingRules = layers["TBD_PROMPT_OPERATING_RULES"] { parts.append(operatingRules) }
        if let brief = layers["TBD_PROMPT_BRIEF"] { parts.append(brief) }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n---\n\n")
    }
}
