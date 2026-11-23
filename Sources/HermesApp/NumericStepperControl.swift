import AppKit

/// A visible numeric value paired with AppKit's vertical increment/decrement arrows.
final class NumericStepperControl: NSView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    let stepper = NSStepper()
    var onChange: ((Double?) -> Void)?

    private let range: ClosedRange<Double>
    private let increment: Double
    private let suffix: String
    private var displayedValue: Double?
    private var isApplyingChange = false
    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    init(label: String, range: ClosedRange<Double>, increment: Double, suffix: String) {
        self.range = range
        self.increment = increment
        self.suffix = suffix
        super.init(frame: .zero)

        field.controlSize = .regular
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.alignment = .right
        field.placeholderString = "Mixed"
        field.target = self
        field.action = #selector(commitField)
        field.delegate = self
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        field.setAccessibilityLabel(label)

        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = increment
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.target = self
        stepper.action = #selector(step)
        stepper.setAccessibilityLabel(label)

        for control in [field, stepper] {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            stepper.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func display(_ value: Double?, fallback: Double) {
        // Retain partially typed values while the document updates behind the popover.
        guard isApplyingChange || field.currentEditor() == nil else { return }
        displayedValue = value
        field.stringValue = value.map(formatted) ?? ""
        stepper.doubleValue = min(range.upperBound, max(range.lowerBound, value ?? fallback))
    }

    func setEnabled(_ enabled: Bool) {
        field.isEnabled = enabled
        stepper.isEnabled = enabled
    }

    private func formatted(_ value: Double) -> String {
        (numberFormatter.string(from: NSNumber(value: value)) ?? String(value)) + suffix
    }

    private func parsedValue() -> Double? {
        let text = field.stringValue.replacingOccurrences(of: "×", with: "")
            .replacingOccurrences(of: "pt", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Double requires the complete string, unlike NumberFormatter's permissive prefix parsing.
        let normalized = text.replacingOccurrences(of: numberFormatter.decimalSeparator, with: ".")
        guard let value = Double(normalized), value.isFinite, range.contains(value),
              increment != 1 || value.rounded() == value else { return nil }
        return value
    }

    func controlTextDidChange(_ notification: Notification) {
        if let value = parsedValue() { stepper.doubleValue = value }
    }

    @objc private func commitField() {
        if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == "Style Default" {
            restoreDefault()
            return
        }
        guard let value = parsedValue() else {
            if displayedValue == nil && field.stringValue.isEmpty { return }
            NSSound.beep()
            field.stringValue = displayedValue.map(formatted) ?? ""
            return
        }
        apply(value)
    }

    @objc private func step() {
        // Round decimal increments so 1.4 + 0.1 never persists as 1.499999999… .
        let value = (stepper.doubleValue * 100).rounded() / 100
        apply(value)
    }

    private func apply(_ value: Double) {
        displayedValue = value
        field.stringValue = formatted(value)
        stepper.doubleValue = value
        notifyChange(value)
    }

    private func notifyChange(_ value: Double?) {
        isApplyingChange = true
        defer { isApplyingChange = false }
        onChange?(value)
    }

    @objc func restoreDefault() {
        notifyChange(nil)
    }
}
