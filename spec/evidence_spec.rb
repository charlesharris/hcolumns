# frozen_string_literal: true

RSpec.describe HColumns::Evidence do
  now = FIXED_NOW
  day = HColumns::Evidence::DAY_SECONDS

  it "does not decay structural or human evidence, however old" do
    ancient = now - (1000 * day)
    expect(described_class.decay(kind: :structure, observed_at: ancient, now: now)).to eq(1.0)
    expect(described_class.decay(kind: :human, observed_at: ancient, now: now)).to eq(1.0)
  end

  it "halves history evidence after one half-life (90d)" do
    expect(described_class.decay(kind: :history, observed_at: now - (90 * day), now: now))
      .to be_within(1e-9).of(0.5)
  end

  it "treats future-dated observations as fully fresh" do
    expect(described_class.decay(kind: :history, observed_at: now + day, now: now)).to eq(1.0)
  end

  it "raises on an unknown evidence kind" do
    expect { described_class.kind(:nonsense) }.to raise_error(ArgumentError)
  end
end
