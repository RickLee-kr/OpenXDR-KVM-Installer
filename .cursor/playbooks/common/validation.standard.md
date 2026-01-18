# Validation Standard Playbook
## (Full Configuration Validation)

This playbook defines how validation logic must be reviewed or extended.

---

## 1. Validation Philosophy

- Validation is **read-only**
- Validation never:
  - Modifies system state
  - Modifies configuration
  - Writes to state files

---

## 2. Severity Levels (Fixed)

- OK    : Requirement satisfied
- WARN  : Non-blocking issue, recommendation
- FAIL  : Blocking issue, deployment must not proceed

These meanings must never be changed.

---

## 3. Adding New Validation Checks

When adding a validation item:

- Check must be deterministic
- Check must be idempotent
- Output must follow existing format exactly
- Severity must be justified

---

## 4. Validation Output Rules

- Summary must appear first
- Detailed output may follow
- FAIL results must block deployment
- WARN results must never block deployment

---

## 5. Forbidden Actions

- Auto-fixing detected issues
- Prompting user input during validation
- Mixing validation with deployment logic

