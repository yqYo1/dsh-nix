# The official bundle catalog used by this repository.
#
# Upstream remains authoritative for the actual bundle definitions and the
# drift checks in flake.nix compare this catalog with the pinned source.  Keep
# the lists here so the flake, module, checks, and tests do not each carry a
# separate copy.
{
  # Bundles of the shipped profile templates (upstream PROFILE_TEMPLATES).
  profileTemplates = {
    acp = [
      "@deepseek-ai/dsh-base"
      "@deepseek-ai/dsh-acp-app"
    ];
    headless = [
      "@deepseek-ai/dsh-base"
      "@deepseek-ai/dsh-headless"
    ];
    sdk = [
      "@deepseek-ai/dsh-base"
      "@deepseek-ai/dsh-sdk-app"
    ];
    "sdk-minimal" = [
      "@deepseek-ai/dsh-sdk-minimal"
    ];
    web = [
      "@deepseek-ai/dsh-base"
      "@deepseek-ai/dsh-web-app"
    ];
  };

  # Shipped optional bundles (upstream OPTIONAL_BUNDLES).
  optional = [
    "@deepseek-ai/dsh-personalized-recommendations"
    "@deepseek-ai/dsh-cua-bundle"
    "@deepseek-ai/dsh-experimental-session-search"
    "@deepseek-ai/dsh-experimental-ralph-bundle"
    "@deepseek-ai/dsh-experimental-terminal-bundle"
    "@deepseek-ai/dsh-experimental-badge-skill-bundle"
    "@deepseek-ai/dsh-experimental-session-titles-bundle"
    "@deepseek-ai/dsh-experimental-voice-input-bundle"
    "@deepseek-ai/dsh-experimental-cot-translation-bundle"
    "@deepseek-ai/dsh-experimental-auto-review"
    "@deepseek-ai/dsh-experimental-inspector-profile"
    "@deepseek-ai/dsh-experimental-plugin-market-bundle"
    "@deepseek-ai/dsh-experimental-tool-worktree"
    "@deepseek-ai/dsh-experimental-liveshare"
    "@deepseek-ai/dsh-experimental-forge-bundle"
    "@deepseek-ai/dsh-deepseek-chat-import"
  ];

  # Catalog-only bundles (upstream ON_DEMAND_BUNDLES).
  onDemand = [
    "@deepseek-ai/dsh-subagent-codex"
    "@deepseek-ai/dsh-subagent-claude-code"
  ];
}
