# frozen_string_literal: true

RSpec.describe HColumns::ColumnBuilder do
  now = FIXED_NOW
  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:orders) { HColumns::Providers::InMemoryFixture.orders_id }
  let(:column) { described_class.new(graph).build(orders, now: now) }

  def render(col)
    HColumns::Renderers::Text.new.render(col)
  end

  it "groups outgoing edges by relation type" do
    rels = column.groups.map(&:relation)
    expect(rels).to include(:PAIR, :CO_CHANGED_WITH, :CHANGED_BY)
  end

  it "excludes incoming relations (README MENTIONS orders is not in orders' column)" do
    expect(column.groups.map(&:relation)).not_to include(:MENTIONS)
  end

  it "ranks the confirmed source/test pair group first" do
    expect(column.groups.first.relation).to eq(:PAIR)
    expect(column.groups.first.entries.first.maturity).to eq(:confirmed)
  end

  it "ranks co-change neighbours by score (payments over the older, weaker inventory)" do
    cc = column.groups.find { |g| g.relation == :CO_CHANGED_WITH }
    expect(cc.entries.map { |e| e.target.name }).to eq(["src/payments.rb", "src/inventory.rb"])
  end

  it "produces identical output on repeated builds (determinism)" do
    expect(render(described_class.new(graph).build(orders, now: now)))
      .to eq(render(described_class.new(graph).build(orders, now: now)))
  end

  it "raises on an unknown node" do
    expect { described_class.new(graph).build("obj:nope", now: now) }
      .to raise_error(ArgumentError, /no such node/)
  end
end
