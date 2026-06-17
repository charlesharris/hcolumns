# frozen_string_literal: true

RSpec.describe HColumns::Lens do
  describe "presets" do
    it "default is neutral: no floor, no mix, no scope, admits everything" do
      lens = described_class.preset(:default)
      expect(lens.tuner.floor).to eq(0.0)
      expect(lens.tuner.evidence_mix).to be_empty
      expect(lens.scope).to be_nil
      expect(lens.admits?(:ANYTHING)).to be(true)
    end

    it "reviewer is strict and discounts inference; explorer keeps the floor open" do
      reviewer = described_class.preset(:reviewer)
      explorer = described_class.preset(:explorer)
      expect(reviewer.tuner.floor).to be > 0
      expect(reviewer.tuner.evidence_mix[:inference]).to be < 1.0
      expect(explorer.tuner.floor).to eq(0.0)
      expect(explorer.tuner.evidence_mix[:inference]).to be > 1.0
    end

    it "raises on an unknown preset" do
      expect { described_class.preset(:nope) }.to raise_error(ArgumentError, /unknown lens preset/)
    end
  end

  describe "cycle" do
    it "walks the registered ring in order and wraps around" do
      expect(described_class.names).to eq(%i[default reviewer explorer git filesystem])
      expect(described_class.cycle(:default).name).to eq(:reviewer)
      expect(described_class.cycle(:explorer).name).to eq(:git)
      expect(described_class.cycle(:filesystem).name).to eq(:default)
    end

    it "preset returns the right subclass for each registered name" do
      expect(described_class.preset(:git)).to be_a(HColumns::Lenses::GitLens)
      expect(described_class.preset(:reviewer)).to be_a(HColumns::Lenses::ReviewerLens)
      expect(described_class.preset(:default)).to be_an_instance_of(described_class)
    end
  end

  describe "scope" do
    it "only: admits just the listed families" do
      lens = described_class.new(name: :x, scope: { only: [:CONTAINS] })
      expect(lens.admits?(:CONTAINS)).to be(true)
      expect(lens.admits?(:DEFINES)).to be(false)
    end

    it "hide: admits everything but the listed families" do
      lens = described_class.new(name: :y, scope: { hide: [:CONTAINS] })
      expect(lens.admits?(:CONTAINS)).to be(false)
      expect(lens.admits?(:DEFINES)).to be(true)
    end
  end

  describe "with_floor" do
    it "overrides the floor but keeps name, mix, and scope" do
      base = described_class.new(name: :reviewer, tuner: HColumns::Tuner.new({ floor: 0.2 },
                                                                             evidence_mix: { structure: 1.4 }),
                                 scope: { hide: [:CONTAINS] })
      tuned = base.with_floor(0.7)
      expect(tuned.tuner.floor).to eq(0.7)
      expect(tuned.tuner.evidence_mix).to eq({ structure: 1.4 })
      expect(tuned.scope).to eq({ hide: [:CONTAINS] })
      expect(tuned.name).to eq(:reviewer)
    end
  end
end

RSpec.describe "lensing a column" do
  def now = FIXED_NOW
  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:orders) { HColumns::Providers::InMemoryFixture.orders_id }

  def column(lens)
    HColumns::ColumnBuilder.new(graph, lens: lens).build(orders, now: now)
  end

  it "a stricter floor never surfaces more entries than a neutral lens" do
    neutral = column(HColumns::Lens.preset(:default)).entries.size
    strict  = column(HColumns::Lens.preset(:reviewer)).entries.size
    expect(strict).to be <= neutral
    expect(neutral).to be > 0
  end

  it "scope hides one relation family and leaves the others intact" do
    base = column(HColumns::Lens.preset(:default))
    dropped = base.groups.first.relation
    scoped = column(HColumns::Lens.new(name: :scoped, scope: { hide: [dropped] }))
    expect(scoped.groups.map(&:relation)).not_to include(dropped)
    expect(scoped.groups.map(&:relation)).to match_array(base.groups.map(&:relation) - [dropped])
  end
end

RSpec.describe "live retune via Cascade" do
  def now = FIXED_NOW
  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:workspace) { HColumns::Workspace.new(graph: graph) }
  # orders' column is all probabilistic (PAIR/co-change/authorship), so the floor
  # can actually move it — a deterministic column (e.g. repo CONTAINS) cannot be
  # floored out, which is the point of deterministic evidence.
  let(:root) { HColumns::Providers::InMemoryFixture.orders_id }
  subject(:cascade) { HColumns::Cascade.new(workspace, root, now: now) }

  it "cycle_lens swaps the workspace lens and rebuilds the walked path" do
    expect(cascade.lens_label).to start_with("default")
    cascade.cycle_lens
    expect(workspace.lens.name).to eq(:reviewer)
    expect(cascade.lens_label).to start_with("reviewer")
  end

  it "raising the floor past every edge empties the column; lowering restores it" do
    before = cascade.active_entries.size
    expect(before).to be > 0
    cascade.adjust_floor(1.0) # above even deterministic structure (~0.97)
    expect(cascade.active_entries.size).to be < before
    cascade.adjust_floor(-1.0)
    expect(cascade.active_entries.size).to eq(before)
  end

  it "rebuild! clamps a cursor the shorter column would put out of range" do
    cascade.active.cursor = cascade.active_entries.size - 1
    cascade.adjust_floor(1.0)
    expect(cascade.active.cursor).to be <= [cascade.active_entries.size - 1, 0].max
  end
end
