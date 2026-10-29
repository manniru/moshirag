// Product branding shown in the web UI (Brilliant Esystems build of MoshiRAG).
export const brand = {
  company: "Brilliant Esystems Limited",
  companyUrl: "https://brilliant.ng/",
  name: "Brilliant",
  suffix: "Voice AI",
  assistant: "Brilliant AI",
  logo: "/assets/brilliant-logo.png",
  // Build with VITE_BRAND_RETRIEVAL=0 for a server without retrieval (plain Moshi, e.g. moshi_mlx
  // on a Mac): the landing text then leaves retrieval out and the retrieval panel is hidden.
  retrieval: import.meta.env.VITE_BRAND_RETRIEVAL !== "0",
  // Kyutai's post-session survey compares Moshi with MoshiRAG; it does not apply to this build.
  showFeedbackSurvey: false,
};
