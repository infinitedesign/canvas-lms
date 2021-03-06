#
# Copyright (C) 2011-12 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

# Contains a dictionary of arrays with hashes in them. This is so that
# we can get all the submissions for a course grouped by date and
# ordered by date, person, then assignment.  Since working with this is
# a loop in a loop in a loop, it gets a little awkward for controllers
# and views, so I contain it in a class with some helper methods.  The
# dictionary comes from facets, a stable and mature library that's been
# around for years.  A dictionary is just an ordered hash.  
# 
# To use this: 
# 
# s = SubmissionList.new(course)
# s.each {|e| # lists each submission hash in the right order }
# s.each_day {|e| # lists each day with an array of submission hashes }
# 
# The submission hash has some very useful meta data in there:
# 
# :grader => printable name of the grader, or Graded on submission if unknown
# :grader_id => user_id of the grader
# :previous_grade => the grade previous to this one, or nil
# :current_grade => the most current grade, the last submission for this assignment and student
# :new_grade => the new grade this submission received
# :assignment_name => a printable name of the assignment
# :student_user_id => the user_id of the student
# :course_id => the course id
# :assignment_id => the assignment id
# :student_name => a printable name of the student
# :graded_on => the day (not the time) the submission was made
# 
# The version data is actually pulled from some yaml storage through 
# simply_versioned.
class SubmissionList

    VALID_KEYS = [
      :assignment_id, :assignment_name, :attachment_id, :attachment_ids,
      :body, :course_id, :created_at, :current_grade, :current_graded_at,
      :current_grader, :grade_matches_current_submission, :graded_at,
      :graded_on, :grader, :grader_id, :group_id, :id, :new_grade,
      :new_graded_at, :new_grader, :previous_grade, :previous_graded_at,
      :previous_grader, :process_attempts, :processed, :published_grade,
      :published_score, :safe_grader_id, :score, :student_entered_score,
      :student_user_id, :submission_id, :student_name, :submission_type,
      :updated_at, :url, :user_id, :workflow_state
    ].freeze 
  
  class << self
    # Shortcut for SubmissionList.each(course) { ... }
    def each(course, &block)
      sl = new(course)
      sl.each(&block)
    end
    
    def each_day(course, &block)
      sl = new(course)
      sl.each_day(&block)
    end
    
    def days(course)
      new(course).days
    end
    
    def submission_entries(course)
      new(course).submission_entries
    end
    
    def list(course)
      new(course).list
    end
  end
  
  # The course
  attr_reader :course
  
  # The dictionary of submissions
  attr_reader :list
  
  def initialize(course)
    raise ArgumentError, "Must provide a course." unless course && course.is_a?(Course)
    @course = course
    process
  end
  
  # An iterator on a sorted and filtered list of submission versions.
  def each(&block)
    self.submission_entries.each do |entry|
      yield(entry)
    end
  end
  
  # An iterator on the day only, not each submission
  def each_day(&block)
    self.list.each &block
  end
  
  # An array of days with an array of grader open structs for that day and course.
  # TODO - This needes to be refactored, it is way slow and I cant figure out why.
  def days
    # start = Time.now
    # current = Time.now
    # puts "----------------------------------------------"
    # puts "starting"
    # puts "---------------------------------------------------------------------------------"
    self.list.map do |day, value|
      # puts "-----------------------------------------------item #{Time.now - current}----------------------------" 
      # current = Time.now
      OpenObject.new(:date => day, :graders => graders_for_day(day))
    end
    # puts "----------------------------------------------"
    # puts Time.now - start
    # puts "---------------------------------------------------------------------------------"
    # foo
  end

  # A filtered list of hashes of all submission versions that change the
  # grade with all the meta data finally included. This list can be sorted
  # and displayed. 
  def submission_entries
    return @submission_entries if @submission_entries
    @submission_entries = filtered_submissions.map do |s|
      entry = current_grade_map[s[:id]]
      s[:current_grade] = entry.grade
      s[:current_graded_at] = entry.graded_at
      s[:current_grader] = entry.grader
      s
    end
    trim_keys(@submission_entries)
  end

  # A cleaner look at a SubmissionList
  def inspect
    "SubmissionList: course: #{self.course.name} submissions used: #{self.submission_entries.size} days used: #{self.list.keys.inspect} graders: #{self.graders.map(&:name).inspect}"
  end

  protected
    # Returns an array of graders with an array of assignment open structs
    def graders_for_day(day)
      hsh = self.list[day].inject({}) do |h, submission|
        grader = submission[:grader]
        h[grader] ||= OpenObject.new(
          :assignments => assignments_for_grader_and_day(grader, day), 
          :name => grader, 
          :grader_id => submission[:grader_id]
        )
        h
      end
      hsh.values
    end
  
    # Returns an array of assignments with an array of submission open structs.
    def assignments_for_grader_and_day(grader, day)
      start = Time.now
      hsh = submission_entries.find_all {|e| e[:grader] == grader and e[:graded_on] == day}.inject({}) do |h, submission|
        assignment = submission[:assignment_name]
        h[assignment] ||= OpenObject.new(
          :name => assignment, 
          :assignment_id => submission[:assignment_id],
          :submissions => []
        )
      
        h[assignment].submissions << OpenObject.new(submission)

        h
      end
    
      hsh.each do |k, v|
        v.submission_count = v.submissions.size
      end
      # puts "-------------------------------Time Spent in assignments_for_grader_and_day: #{Time.now-start}-------------------------------"
      hsh.values
    end
  
    # Produce @list, wich is a sorted, filtered, list of submissions with
    # all the meta data we need and no banned keys included. 
    def process
      @list = self.submission_entries.sort(&sort_block_for_displaying).inject(Dictionary.new) do |d, se|
        d[se[:graded_on]] ||= []
        d[se[:graded_on]] << se
        d
      end
    end
    
    # A hash of the current grades of each submission, keyed by submission.id
    def current_grade_map
      @current_grade_map ||= self.course.submissions.inject({}) do |hash, submission|
        grader = if submission.grader_id.present?
          self.grader_map[submission.grader_id].try(:name)
        end
        grader ||= I18n.t('gradebooks.history.graded_on_submission', 'Graded on submission')

        hash[submission.id] = OpenObject.new(:grade     => submission.grade,
                                             :graded_at => submission.graded_at,
                                             :grader    => grader)
        hash
      end
    end

    # Ensures that the final product only has approved keys in it.  This
    # makes our final product much more yummy. 
    def trim_keys(list)
      list.each do |hsh|
        hsh.delete_if { |key, v| ! VALID_KEYS.include?(key) }
      end
    end
    
    # Creates a list of any submissions that change the grade. Adds:
    # * previous_grade
    # * previous_graded_at
    # * previous_grader
    # * new_grade
    # * new_graded_at
    # * new_grader
    # * current_grade
    # * current_graded_at
    # * current_grader
    def filtered_submissions
      return @filtered_submissions if @filtered_submissions
      full_hash_list.sort! &sort_block_for_filtering
      prior_submission_id, prior_grade, prior_score, prior_graded_at, prior_grader = nil
      
      @filtered_submissions = full_hash_list.inject([]) do |l, h|
        
        # Don't update prior_grade or prior_submission unless there is a grade.
        # Also don't add it to the list.  Just pass the list to the next
        # iteration of the block. 
        next(l) unless h[:score]

        # If the submission is different (not null for the first one, or just
        # different than the last one), set the previous_grade to nil (this is
        # the first version that changes a grade), set the new_grade to this
        # version's grade, and add this to the list. 
        if prior_submission_id != h[:submission_id]
          h[:previous_grade] = nil
          h[:previous_graded_at] = nil
          h[:previous_grader] = nil
          h[:new_grade] = h[:grade]
          h[:new_score] = h[:score]
          h[:new_graded_at] = h[:graded_at]
          h[:new_grader] = h[:grader]
          l << h 
        # If the prior_grade is different than the grade for this version, the
        # grade for this submission has been changed.  That's because we know
        # that this submission must be the same as the prior submission. 
        # Set the prevous grade and the new grade and add this to the list.
        # Remove the old submission so that it doesn't show up twice in the
        # grade history.
        elsif prior_score != h[:score]
          l.pop if prior_graded_at.try(:to_date) == h[:graded_at].try(:to_date) && prior_grader == h[:grader]
          h[:previous_grade] = prior_grade
          h[:previous_graded_at] = prior_graded_at
          h[:previous_grader] = prior_grader
          h[:new_grade] = h[:grade]
          h[:new_score] = h[:score]
          h[:new_graded_at] = h[:graded_at]
          h[:new_grader] = h[:grader]
          l << h
        end
        
        # At this point, we are only working with versions that have changed a
        # grade.  Go ahead and save that grade and save this version as the
        # prior version and iterate. 
        prior_grade = h[:grade]
        prior_score = h[:score]
        prior_graded_at = h[:graded_at]
        prior_grader = h[:grader]
        prior_submission_id = h[:submission_id]
        l
      end
    end
    
    # Sorts by submission then updated at in ascending order.  So:
    # submission 1 1/1/2009, submission 1 1/15/2009, submission 2 1/1/2009
    def sort_block_for_filtering
      lambda{|a, b|
        tier_1 = a[:id] <=> b[:id]
        tier_2 = a[:updated_at] <=> b[:updated_at]
        tier_1 == 0 ? tier_2 : tier_1
      }
    end
    
    def sort_block_for_displaying
      lambda{|a, b|
        
        first_tier = if b[:graded_at] and a[:graded_at]
          b[:graded_at] <=> a[:graded_at]
        elsif b[:graded_at]
          1
        elsif a[:graded_at]
          -1
        else
          0
        end
        
        case first_tier
        when -1
          -1
        when 1
          1
        when 0
          case a[:safe_grader_id] <=> b[:safe_grader_id]
          when -1
            -1
          when 1
            1
          when 0
            a[:assignment_id] <=> b[:assignment_id]
          end
        end
      }
    end
    
    # A list of all versions in YAML format
    def yaml_list
      @yaml_list ||= self.course.submissions.map {|s| s.versions.map { |v| v.yaml } }.flatten
    end
    
    # A list of hashes.  All the versions of all the submissions for a
    # course, unfiltered and unsorted. 
    def raw_hash_list
      @hash_list ||= yaml_list.map { |y| YAML.load(y).symbolize_keys }
    end
    
    # Still a list of unsorted, unfiltered hashes, but the meta data is inserted at this point
    def full_hash_list
      @full_hash_list ||= self.raw_hash_list.map do |h|
        h[:grader] = if h[:grader_id] && self.grader_map[h[:grader_id]]
          self.grader_map[h[:grader_id]].name
        else
          I18n.t('gradebooks.history.graded_on_submission', 'Graded on submission')
        end
        h[:safe_grader_id] = h[:grader_id] ? h[:grader_id] : 0
        h[:assignment_name] = self.assignment_map[h[:assignment_id]].title
        h[:student_user_id] = h[:user_id]
        h[:student_name] = self.student_map[h[:user_id]].name
        h[:course_id] = self.course.id
        h[:submission_id] = h[:id]
        h[:graded_on] = h[:graded_at].in_time_zone.to_date if h[:graded_at]

        h
      end
    end
    
    # A unique list of all grader ids
    def all_grader_ids
      @all_grader_ids ||= raw_hash_list.map { |e| e[:grader_id] }.uniq.compact
    end
    
    # A complete list of all graders that have graded submissions for this
    # course as User models 
    def graders
      @graders ||= User.find(:all, :conditions => ['id IN (?)', all_grader_ids])
    end
    
    # A hash of graders by their ids, for easy lookup in full_hash_list
    def grader_map
      @grader_map ||= graders.inject({}) do |h, g|
        h[g.id] = g
        h
      end
    end

    # A unique list of all student ids
    def all_student_ids
      @all_student_ids ||= raw_hash_list.map { |e| e[:user_id] }.uniq.compact
    end
    
    # A complete list of all students that have submissions for this course
    # as User models 
    def students
      @students ||= User.find(:all, :conditions => ['id IN (?)', all_student_ids])
    end
    
    # A hash of students by their ids, for easy lookup in full_hash_list
    def student_map
      @student_map ||= students.inject({}) do |h, s|
        h[s.id] = s
        h
      end
    end

    # A unique list of all assignment ids
    def all_assignment_ids
      @all_assignment_ids ||= raw_hash_list.map { |e| e[:assignment_id] }.uniq.compact
    end
    
    # A complete list of assignments that have submissions for this course
    def assignments
      @assignments ||= Assignment.find(:all, :conditions => ['id IN (?)', all_assignment_ids])
    end
    
    # A hash of assignments by their ids, for easy lookup in full_hash_list
    def assignment_map
      @assignment_map ||= assignments.inject({}) do |h, a|
        h[a.id] = a
        h
      end
    end

end
