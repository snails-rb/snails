# before_action dialect target — the test below drives
# run_before_filters on instances. Registration, send dispatch, halt,
# only/except gating, and owner partitioning are exercised through
# these controllers. There is no per-controller dispatch case: a
# controller defines its filter methods and registers their names.

class HarnessPlainController < ApplicationController
  before_action :mark_ran

  def mark_ran
    @ran = true
  end

  def filter_ran?
    !@ran.nil?
  end
end

class HarnessHaltController < ApplicationController
  before_action :halt_filter
  before_action :mark_ran

  def halt_filter
    render("denied", status: :unauthorized)
  end

  def mark_ran
    @ran = true
  end

  def filter_ran?
    !@ran.nil?
  end
end

# Registered name with no matching method — method dispatch must fail with
# a clear error (NoMethodError), not silently skip the filter.
class HarnessMissingMethodController < ApplicationController
  before_action :unmapped_filter
end

# only: gate — the first filter runs on create only, the second on
# every action.
class HarnessOnlyController < ApplicationController
  before_action :mark_create, only: :create
  before_action :mark_all

  def mark_create
    @create_ran = true
  end

  def mark_all
    @all_ran = true
  end

  def create_ran?; !@create_ran.nil?; end
  def all_ran?; !@all_ran.nil?; end
end

# only: gated halt — the filter renders on create, so the later
# filter never runs.
class HarnessOnlyHaltController < ApplicationController
  before_action :halt_filter, only: :create
  before_action :mark_ran

  def halt_filter
    render("denied", status: :unauthorized)
  end

  def mark_ran
    @ran = true
  end

  def filter_ran?
    !@ran.nil?
  end
end

# except: gate — runs everywhere but the excluded action.
class HarnessExceptController < ApplicationController
  before_action :mark_all, except: :show

  def mark_all
    @all_ran = true
  end

  def all_ran?; !@all_ran.nil?; end
end

# The filter method lives on the parent; the child registers the name —
# the shared-filter pattern (registration cannot propagate automatically,
# but method dispatch reaches ancestors).
class HarnessParentController < ApplicationController
  def shared_filter
    @shared = true
  end

  def shared_ran?
    !@shared.nil?
  end
end

class HarnessChildController < HarnessParentController
  before_action :shared_filter
end
