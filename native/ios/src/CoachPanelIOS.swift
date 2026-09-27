//
//  CoachPanelIOS.swift
//  人机中国象棋 · 教学侧栏 (iOS / UIKit 版)
//
//  与 macOS 版 CoachPanel 公开面一致: update(text:eval:color:)。
//  竖屏时在棋盘下方, 横屏时在棋盘右侧。
//
#if canImport(UIKit)
import UIKit

/// 形势评估条 (对应 macOS EvalBarView, 画法一致)
final class EvalBarView: UIView {
    var eval = 0
    var color = RED
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        let b = bounds
        XColor(crossWhite: 0.85, alpha: 1).setFill()
        XBezierPath(roundedRect: b, cornerRadius: 4).fill()
        let ratio = max(-1.0, min(1.0, Double(eval) / 1500.0))
        let mid = b.width / 2
        let w = abs(ratio) * (b.width / 2)
        let col: XColor = ratio >= 0
            ? XColor(crossRed: 0.78, green: 0.16, blue: 0.12, alpha: 1)
            : XColor(crossRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        col.setFill()
        let x = ratio >= 0 ? mid - w : mid
        XBezierPath(roundedRect: CGRect(x: x, y: 1, width: w, height: b.height - 2),
                    cornerRadius: 3).fill()
        _ = cg
    }
}

class CoachPanel: UIView {
    private let titleLabel = UILabel()
    let evalBar = EvalBarView()
    private let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = UIColor(white: 0.97, alpha: 1)
        layer.cornerRadius = 10
        layer.masksToBounds = true

        titleLabel.text = "局势评估"
        titleLabel.font = UIFont.boldSystemFont(ofSize: 12)
        titleLabel.textColor = .darkGray
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        evalBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(evalBar)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = UIFont.systemFont(ofSize: 12)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            evalBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            evalBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            evalBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            evalBar.heightAnchor.constraint(equalToConstant: 16),
            textView.topAnchor.constraint(equalTo: evalBar.bottomAnchor, constant: 6),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    func update(text: String, eval: Int, color: String) {
        textView.text = text
        let loc = (text as NSString).length
        textView.scrollRangeToVisible(NSRange(location: loc, length: 0))
        evalBar.eval = eval; evalBar.color = color; evalBar.setNeedsDisplay()
    }
}

#endif
