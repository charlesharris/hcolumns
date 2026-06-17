# frozen_string_literal: true

RSpec.describe "golden column render" do
  it "renders the src/orders.rb column as expected" do
    now = FIXED_NOW
    graph = HColumns::Providers::InMemoryFixture.build(now: now)
    column = HColumns::ColumnBuilder.new(graph).build(
      HColumns::Providers::InMemoryFixture.orders_id, now: now
    )
    golden("orders_column.txt", HColumns::Renderers::Text.new.render(column))
  end

  it "renders the same orders column under the reviewer lens (strict, structure-first)" do
    now = FIXED_NOW
    graph = HColumns::Providers::InMemoryFixture.build(now: now)
    column = HColumns::ColumnBuilder.new(graph, lens: HColumns::Lens.preset(:reviewer)).build(
      HColumns::Providers::InMemoryFixture.orders_id, now: now
    )
    golden("orders_column_reviewer.txt", HColumns::Renderers::Text.new.render(column))
  end

  it "renders the repo › src cascade side by side" do
    now = FIXED_NOW
    graph = HColumns::Providers::InMemoryFixture.build(now: now)
    repo = graph.nodes.find { |n| n.name == "repo/" }.id
    cascade = HColumns::Cascade.new(HColumns::Workspace.new(graph: graph), repo, now: now)
    cascade.active.cursor = cascade.active_entries.index { |e| e.target.name == "src" }
    cascade.into

    golden("cascade_repo_src.txt", HColumns::Renderers::CascadeText.new(color: false).render(cascade))
  end
end
