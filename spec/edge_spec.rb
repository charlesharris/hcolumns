# frozen_string_literal: true

RSpec.describe HColumns::Edge do
  now = FIXED_NOW
  day = HColumns::Evidence::DAY_SECONDS

  def obs(kind:, weight: 1.0, age_days: 0, now:, day:)
    HColumns::Observation.new(provider: :test, subject_id: "a", target_id: "b",
                              edge_type: :REL, weight: weight, evidence_kind: kind,
                              observed_at: now - (age_days * day))
  end

  it "is zero-confidence with no observations" do
    edge = described_class.new(subject_id: "a", target_id: "b", type: :REL)
    expect(edge.confidence(now: now)).to eq(0.0)
    expect(edge.recency(now: now)).to eq(0.0)
    expect(edge.maturity(now: now)).to eq(:observed)
  end

  it "raises confidence with more evidence, squashed below 1" do
    edge = described_class.new(subject_id: "a", target_id: "b", type: :REL)
    edge.add(obs(kind: :history, now: now, day: day))
    c1 = edge.confidence(now: now)
    edge.add(obs(kind: :history, now: now, day: day))
    c2 = edge.confidence(now: now)
    expect(c2).to be > c1
    expect(c2).to be < 1.0
  end

  it "lowers confidence as history evidence ages" do
    fresh = described_class.new(subject_id: "a", target_id: "b", type: :REL)
            .add(obs(kind: :history, now: now, day: day))
    stale = described_class.new(subject_id: "a", target_id: "b", type: :REL)
            .add(obs(kind: :history, age_days: 180, now: now, day: day))
    expect(stale.confidence(now: now)).to be < fresh.confidence(now: now)
  end

  it "marks any human-confirmed edge as confirmed" do
    edge = described_class.new(subject_id: "a", target_id: "b", type: :REL)
           .add(obs(kind: :human, now: now, day: day))
    expect(edge.maturity(now: now)).to eq(:confirmed)
  end

  it "treats deterministic (verifiable) evidence as full confidence + confirmed" do
    edge = described_class.new(subject_id: "a", target_id: "b", type: :REL)
           .add(obs(kind: :structure, age_days: 9999, now: now, day: day))
    expect(edge.confidence(now: now)).to eq(1.0)   # exactly, however old — it's a fact
    expect(edge.maturity(now: now)).to eq(:confirmed)
  end

  it "marks a strong multi-kind (probabilistic) edge as reinforced" do
    edge = described_class.new(subject_id: "a", target_id: "b", type: :REL)
    edge.add(obs(kind: :behavior, now: now, day: day))
    edge.add(obs(kind: :history, weight: 2.0, now: now, day: day))
    expect(edge.evidence_kinds.size).to eq(2)
    expect(edge.confidence(now: now)).to be < 1.0
    expect(edge.maturity(now: now)).to eq(:reinforced)
  end
end
