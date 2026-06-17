# frozen_string_literal: true

RSpec.describe HColumns::Tuner do
  def now = FIXED_NOW

  # A one-observation edge of a given evidence kind — enough to exercise the mix
  # and the floor in isolation from any provider.
  def edge_of(kind)
    HColumns::Edge.new(subject_id: "a", target_id: "b", type: :REL).add(
      HColumns::Observation.new(provider: :t, subject_id: "a", target_id: "b",
                                edge_type: :REL, evidence_kind: kind, observed_at: now)
    )
  end

  it "with no mix reports the edge's own confidence (identical to layer one)" do
    edge = edge_of(:structure)
    expect(described_class.new.confidence(edge, now: now)).to eq(edge.confidence(now: now))
  end

  it "evidence-mix re-weights a kind's contribution up and down" do
    edge = edge_of(:inference)
    base = described_class.new.confidence(edge, now: now)
    up   = described_class.new({}, evidence_mix: { inference: 2.0 }).confidence(edge, now: now)
    down = described_class.new({}, evidence_mix: { inference: 0.1 }).confidence(edge, now: now)
    expect(up).to be > base
    expect(down).to be < base
  end

  it "leaves other kinds untouched when the mix names only one" do
    edge = edge_of(:structure)
    mixed = described_class.new({}, evidence_mix: { inference: 5.0 }).confidence(edge, now: now)
    expect(mixed).to eq(edge.confidence(now: now))
  end

  it "floor is a visibility threshold on the mixed confidence" do
    edge = edge_of(:inference)
    c = described_class.new.confidence(edge, now: now)
    expect(described_class.new({ floor: c + 0.01 }).visible?(edge, now: now)).to be(false)
    expect(described_class.new({ floor: c - 0.01 }).visible?(edge, now: now)).to be(true)
  end

  it "default floor of 0.0 hides nothing" do
    expect(described_class.new.visible?(edge_of(:inference), now: now)).to be(true)
  end
end
