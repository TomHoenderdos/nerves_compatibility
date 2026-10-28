// Package picker and OAuth-approval popup behaviour for /request-scan. Moved
// out of a <script> tag in request_scan.html.heex: AGENTS.md forbids raw
// inline <script> tags in heex, and the portal's CSP now carries no
// 'unsafe-inline' in script-src, so an inline tag here would be silently
// blocked by the browser rather than merely against house style.
export function initPackagePicker() {
  const packagePicker = document.querySelector("[data-package-picker]");

  if (packagePicker) {
    const entry = packagePicker.querySelector("[data-package-entry]");
    const listInput = packagePicker.querySelector("[data-package-list-input]");
    const chips = packagePicker.querySelector("[data-package-chips]");
    const emptyState = packagePicker.querySelector("[data-package-empty]");
    const suggestions = document.querySelector("#hex-package-suggestions");
    const submitButton = packagePicker.querySelector("[data-verification-submit]");
    const methodInputs = packagePicker.querySelectorAll("[data-verification-method]");
    let selectedPackages = listInput.value.split(/\s+/).filter(Boolean);
    let searchTimer;

    function normalizePackage(value) {
      return value.trim().toLowerCase();
    }

    function packageTokens(value) {
      return value.split(/[\s,;]+/).map(normalizePackage).filter(Boolean);
    }

    function renderPackages() {
      listInput.value = selectedPackages.join("\n");

      chips.querySelectorAll("[data-package-chip]").forEach((chip) => chip.remove());
      emptyState?.classList.toggle("hidden", selectedPackages.length > 0);
      chips.classList.toggle("items-center", selectedPackages.length === 0);

      selectedPackages.forEach((packageName) => {
        const chip = document.createElement("span");
        chip.className = "badge badge-lg gap-2 font-mono";
        chip.dataset.packageChip = packageName;

        const label = document.createTextNode(packageName);
        const removeButton = document.createElement("button");
        removeButton.type = "button";
        removeButton.className = "text-base-content/60 hover:text-error";
        removeButton.dataset.removePackage = packageName;
        removeButton.setAttribute("aria-label", `Remove ${packageName}`);
        removeButton.innerHTML = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 20 20\" fill=\"currentColor\" class=\"size-4\"><path d=\"M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z\" /></svg>";

        chip.append(label, removeButton);
        chips.append(chip);
      });
    }

    function addPackages(value) {
      packageTokens(value).forEach((packageName) => {
        if (!selectedPackages.includes(packageName)) {
          selectedPackages.push(packageName);
        }
      });

      entry.value = "";
      renderPackages();
    }

    function syncVerificationMethod() {
      const selected = packagePicker.querySelector("[data-verification-method]:checked");
      if (!selected) return;

      packagePicker.action = selected.dataset.action;
      submitButton.textContent = selected.dataset.submitLabel;

      methodInputs.forEach((input) => {
        input.closest("label").classList.toggle("border-primary/60", input.checked);
        input.closest("label").classList.toggle("bg-primary/5", input.checked);
      });
    }

    async function fetchHexSuggestions(query) {
      if (query.length < 2) {
        suggestions.innerHTML = "";
        return;
      }

      try {
        const response = await fetch(`/api/packages/hex?query=${encodeURIComponent(query)}`);
        const body = await response.json();
        suggestions.innerHTML = "";

        body.packages.forEach((packageResult) => {
          const option = document.createElement("option");
          option.value = packageResult.name;
          option.label = packageResult.description || packageResult.name;
          suggestions.append(option);
        });
      } catch (_error) {
        suggestions.innerHTML = "";
      }
    }

    packagePicker.querySelector("[data-add-package]")?.addEventListener("click", () => {
      addPackages(entry.value);
      entry.focus();
    });

    entry.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === ",") {
        event.preventDefault();
        addPackages(entry.value);
      }
    });

    entry.addEventListener("input", () => {
      window.clearTimeout(searchTimer);
      searchTimer = window.setTimeout(() => fetchHexSuggestions(normalizePackage(entry.value)), 180);
    });

    chips.addEventListener("click", (event) => {
      const removeButton = event.target.closest("[data-remove-package]");

      if (removeButton) {
        selectedPackages = selectedPackages.filter(
          (packageName) => packageName !== removeButton.dataset.removePackage
        );
        renderPackages();
      }
    });

    methodInputs.forEach((input) => input.addEventListener("change", syncVerificationMethod));

    packagePicker.addEventListener("submit", () => {
      if (entry.value.trim() !== "") {
        addPackages(entry.value);
      }
    });

    renderPackages();
    syncVerificationMethod();
  }

  const hexFlow = document.querySelector("[data-hex-approval-url]");
  const githubFlow = document.querySelector("[data-github-approval-url]");
  const popupFeatures = "popup=yes,width=520,height=720,left=120,top=80,menubar=no,toolbar=no,location=yes,status=no,resizable=yes,scrollbars=yes";

  function openApproval(url, windowName) {
    const popup = window.open(url, windowName, popupFeatures);

    if (popup) {
      popup.focus();
      return true;
    }

    return false;
  }

  if (hexFlow && sessionStorage.getItem("hex-approval-opened") !== hexFlow.dataset.hexDeviceCode) {
    sessionStorage.setItem("hex-approval-opened", hexFlow.dataset.hexDeviceCode);
    openApproval(hexFlow.dataset.hexApprovalUrl, "hex_pm_approval");
  }

  document.querySelector("[data-hex-approval-link]")?.addEventListener("click", (event) => {
    event.preventDefault();
    openApproval(event.currentTarget.href, "hex_pm_approval");
  });

  if (
    githubFlow &&
    sessionStorage.getItem("github-approval-opened") !== githubFlow.dataset.githubDeviceCode
  ) {
    sessionStorage.setItem("github-approval-opened", githubFlow.dataset.githubDeviceCode);
    openApproval(githubFlow.dataset.githubApprovalUrl, "github_approval");
  }

  document.querySelector("[data-github-approval-link]")?.addEventListener("click", (event) => {
    event.preventDefault();
    openApproval(event.currentTarget.href, "github_approval");
  });
}
